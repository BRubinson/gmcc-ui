import SwiftUI

struct YeetViewerView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(YeetViewerStore.self) private var store

    @State private var path: [URL] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(path: $path)
                .navigationDestination(for: URL.self) { url in
                    YeetDocumentView(url: url)
                        .onAppear { store.markOpened(url) }
                }
                .navigationTitle("Yeet Viewer")
                .toolbar {
                    ToolbarItem {
                        Button {
                            store.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
        }
    }
}

private struct LibraryScreen: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(YeetViewerStore.self) private var store

    @Binding var path: [URL]

    var body: some View {
        let quickLoad = store.quickLoad(gmcc: gmcc)
        let recents = store.recents

        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 24) {
                    openFileSection
                    if !quickLoad.isEmpty {
                        quickLoadSection(quickLoad)
                    }
                    if !recents.isEmpty {
                        recentsSection(recents)
                    }
                    if quickLoad.isEmpty && recents.isEmpty {
                        emptyState
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var openFileSection: some View {
        sectionHeader("Open", systemImage: "folder.badge.plus") {
            Button {
                if let url = store.pickFile() {
                    path.append(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open File…")
                            .font(.headline)
                        Text("Choose any .yeet.yaml on disk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
        }
    }

    private func quickLoadSection(_ urls: [URL]) -> some View {
        sectionHeader("Quick Load", systemImage: "bolt.fill") {
            VStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    fileRow(url, subtitle: store.pluginRootRelative(url, gmcc: gmcc))
                }
            }
        }
    }

    private func recentsSection(_ urls: [URL]) -> some View {
        sectionHeader("Recent", systemImage: "clock.arrow.circlepath") {
            VStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    fileRow(url, subtitle: url.deletingLastPathComponent().path)
                }
            }
        } trailing: {
            Button("Clear", role: .destructive) {
                store.clearRecents()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func fileRow(_ url: URL, subtitle: String) -> some View {
        Button {
            path.append(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if gmcc[runtime: .pluginRoot] == nil {
                Text("GMCC_PLUGIN_ROOT is not set in this session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No .yeet.yaml files found under $GMCC_PLUGIN_ROOT.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func sectionHeader<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionHeader(title, systemImage: systemImage, content: content) { EmptyView() }
    }

    @ViewBuilder
    private func sectionHeader<Content: View, Trailing: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                Spacer()
                trailing()
            }
            content()
        }
    }
}
