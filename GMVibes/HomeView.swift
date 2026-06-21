import SwiftUI

struct HomeView: View {
    @Environment(GMCCEnvironment.self) private var gmcc

    var body: some View {
        VStack(spacing: 16) {
            if gmcc.isLoaded {
                Text("GMCC Environment")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(GMCCEnvKey.allCases, id: \.self) { key in
                        envRow(key)
                    }
                }
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Button("Refresh", systemImage: "arrow.clockwise") {
                    gmcc.refresh()
                }
            } else {
                Text("NO GMCC ENV DETECTED")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    gmcc.refresh()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
    }

    @ViewBuilder
    private func envRow(_ key: GMCCEnvKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 180, alignment: .leading)
            Text(gmcc[key] ?? "—")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }
}
