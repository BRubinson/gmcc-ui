import SwiftUI
import GMCCDaemonKit

/// Read-only clarification section — the app's render of the db-native
/// clarification (CLARIFY_GET). Refined goal/detail lead: they supersede the
/// fields the Brief freezes on leaving draft, and this is the one surface
/// built to show them. All clarify writes stay bot/CLI-side.
struct ClarificationPane: View {
    let phase: PromptPhaseStore.Phase<ClarifyGetResponse>

    var body: some View {
        switch phase {
        case .idle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading clarification…").font(.callout).foregroundStyle(.secondary)
            }
        case .absent:
            // Stays READ-ONLY: every clarify write is bot/CLI-side by design.
            Label("Not opened yet — run the bot to start clarification.",
                  systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        case .loaded(let response):
            content(response)
        }
    }

    @ViewBuilder
    private func content(_ response: ClarifyGetResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                statusChip(response.summary.clarificationStatus)
                if !response.summary.backstoryNote.isEmpty {
                    Text(response.summary.backstoryNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            if !response.summary.refinedGoal.isEmpty {
                refinedBlock("Refined Goal", text: response.summary.refinedGoal)
            }
            if !response.summary.refinedDetail.isEmpty {
                refinedBlock("Refined Detail", text: response.summary.refinedDetail)
            }

            ForEach(ClarificationCategory.allCases, id: \.rawValue) { category in
                let rows = response.clarifications
                    .filter { $0.category == category.rawValue }
                    .sorted { $0.seq < $1.seq }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(categoryTitle(category))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(rows, id: \.uuid) { row in
                            questionRow(row)
                        }
                    }
                }
            }

            // Forward compat: a category string the vendored enum doesn't
            // know must not silently vanish from an audit surface — this is
            // the one place an unknown wire value would otherwise lose data.
            let others = response.clarifications
                .filter { ClarificationCategory(rawValue: $0.category) == nil }
                .sorted { $0.seq < $1.seq }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(others, id: \.uuid) { row in
                        questionRow(row)
                    }
                }
            }
        }
    }

    private func refinedBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.blue.opacity(0.06), in: .rect(cornerRadius: 8))
        }
    }

    private func questionRow(_ row: ClarificationRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                rowStatusIcon(row)
                Text(row.question)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }
            if let answer = row.answer, !answer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.answerSource == AnswerSource.botInferred.rawValue
                          ? "cpu" : "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(row.answerSource == AnswerSource.botInferred.rawValue
                              ? "Resolved by the bot" : "Answered by you")
                    Text(answer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowStatusIcon(_ row: ClarificationRow) -> some View {
        switch ClarificationRowStatus(rawValue: row.status) {
        case .answered:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").font(.caption).foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func categoryTitle(_ category: ClarificationCategory) -> String {
        switch category {
        case .goal: return "Goal"
        case .detail: return "Detail"
        }
    }

    @ViewBuilder
    private func statusChip(_ status: ClarificationStatus?) -> some View {
        let (label, color): (String, Color) = switch status {
        case .building: ("Building", .orange)
        case .answering: ("Answering", .blue)
        case .complete: ("Complete", .green)
        case .none: ("—", .gray)
        }
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}
