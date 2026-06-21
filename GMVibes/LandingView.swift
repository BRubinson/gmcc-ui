import SwiftUI
import AppKit

/// App entry point — a CodeEdit-style launcher. Left column of action buttons, right
/// column of recent projects (each with its newest sessions), and a bottom brand bar.
/// When the GM environment hasn't populated, the normal selection is replaced by an
/// error state with copy-paste command rows.
struct LandingView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(GMCCFileSystemEmulation.self) private var fs
    @Environment(\.openWindow) private var openWindow

    @State private var recents = RecentsModel()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if gmcc.isLoaded {
                    launcher
                } else {
                    LandingErrorState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BrandBar()
        }
        .frame(minWidth: 760, minHeight: 520)
        // Re-render reactively when the environment loads/unloads mid-session.
        .animation(.default, value: gmcc.isLoaded)
    }

    private var launcher: some View {
        HStack(alignment: .top, spacing: 0) {
            actionColumn
                .frame(width: 300)
                .padding(20)

            Divider()

            RecentProjectsColumn(recents: recents.recents) { windowID in
                openWindow(value: windowID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        // Page-driven recents refresh — only ticks while the launcher is visible.
        .task(id: gmcc[.projects] ?? "") {
            await recents.loop(fs: fs, gmcc: gmcc)
        }
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActionButton(title: "Open Yeet Viewer", systemImage: "doc.text.magnifyingglass") {
                openWindow(id: "yeet-viewer")
            }
            ActionButton(title: "Open KBites", systemImage: "lightbulb") {
                openWindow(id: "kbites")
            }
            ActionButton(title: "New Project", systemImage: "plus.square.on.square") { }
                .disabled(true)
            ActionButton(title: "Open Projects", systemImage: "folder") {
                openWindow(id: "projects")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Left column button

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Right column: recent projects

private struct RecentProjectsColumn: View {
    let recents: [RecentProject]
    let openSession: (SessionWindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Projects")
                .font(.title3.weight(.semibold))

            if recents.isEmpty {
                Text("No recent projects with sessions.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    GlassEffectContainer(spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(recents) { recent in
                                RecentProjectCard(recent: recent, openSession: openSession)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RecentProjectCard: View {
    let recent: RecentProject
    let openSession: (SessionWindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(recent.project.base.name)
                    .font(.headline)
                Spacer()
            }

            ForEach(recent.sessions) { session in
                Button {
                    openSession(session.windowID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(session.name)
                            .font(.body)
                        if let branch = session.branch, !branch.isEmpty {
                            Text(branch)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "macwindow.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - Error state (env not populated)

private struct LandingErrorState: View {
    @Environment(GMCCEnvironment.self) private var gmcc

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("GM environment not detected")
                .font(.title2.weight(.semibold))
            Text("The full GMCC environment hasn't populated ($GMCC_CKFS_ROOT is unset). Run one of these in a terminal, then Refresh:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                CommandCopyRow(command: "/gmcc:gm_init")
                CommandCopyRow(command: "/gmcc:gm_cleanup")
            }
            .frame(maxWidth: 460)

            Button {
                gmcc.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CommandCopyRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Bottom brand bar

private struct BrandBar: View {
    var body: some View {
        HStack(spacing: 10) {
            appIcon
                .frame(width: 22, height: 22)
            Text("GM Vibes")
                .font(.headline)
            Spacer()
            Text("v\(appVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "mountain.2.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
