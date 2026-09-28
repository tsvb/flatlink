import FlatlinkCore
import FlatlinkPairs
import SwiftUI

/// What the last preview or update found, or how far the current one has got.
struct RunView: View {
    let pair: Pair
    let run: Run

    var body: some View {
        switch run.phase {
        case .idle:
            Label(
                "Preview shows what would change, without changing anything. Update Links links every photo not linked yet. Only links are ever made or removed: your photos stay where they are.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)

        case .scanning(let progress):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.map { "Looking through \(pair.name)… \($0.items.formatted()) items" } ?? "Looking through \(pair.name)…")
                        .monospacedDigit()
                    if let folder = progress?.folder {
                        Text(relative(folder))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))

        case .finished(let outcome):
            OutcomeView(outcome: outcome, pair: pair)
        }
    }

    private func relative(_ folder: String) -> String {
        folder.hasPrefix(pair.source + "/") ? String(folder.dropFirst(pair.source.count + 1)) : folder
    }
}

struct OutcomeView: View {
    let outcome: Outcome
    let pair: Pair

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline

            HStack(spacing: 10) {
                Stat(value: outcome.linked.count, label: outcome.applied ? "linked" : "to link", highlight: !outcome.linked.isEmpty)
                Stat(value: outcome.summary.kept, label: "already linked")
                if !outcome.relinked.isEmpty {
                    Stat(value: outcome.relinked.count, label: outcome.applied ? "relinked" : "to relink", highlight: true)
                }
                if pair.prune || !outcome.pruned.isEmpty {
                    Stat(value: outcome.pruned.count, label: outcome.applied ? "pruned" : "to prune", highlight: !outcome.pruned.isEmpty)
                }
                if outcome.summary.paired > 0 {
                    Stat(value: outcome.summary.paired, label: "paired JPEGs left out")
                }
                if !outcome.issues.isEmpty {
                    Stat(value: outcome.issues.count, label: "need attention", warning: true)
                }
            }

            if !outcome.issues.isEmpty {
                Fold(title: "Needs attention", count: outcome.issues.count, expanded: true) {
                    ForEach(outcome.issues) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title).font(.path).textSelection(.enabled)
                                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            names(outcome.linked, title: outcome.applied ? "Linked" : "Will link", symbol: "link")
            names(outcome.relinked, title: outcome.applied ? "Relinked" : "Will relink", symbol: "arrow.triangle.2.circlepath")
            names(outcome.pruned, title: outcome.applied ? "Pruned" : "Will prune", symbol: "scissors")
        }
    }

    @ViewBuilder private var headline: some View {
        let time = outcome.date.formatted(date: .omitted, time: .shortened)
        if outcome.isUpToDate {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up to date").font(.title3.weight(.semibold))
                    Text("Every photo has its link. Checked at \(time).").foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            }
        } else if outcome.applied && outcome.linked.isEmpty && outcome.relinked.isEmpty && outcome.pruned.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing new to link").font(.title3.weight(.semibold))
                Text("\(outcome.issues.count == 1 ? "One photo still needs" : "\(outcome.issues.count) photos still need") attention. Checked at \(time).")
                    .foregroundStyle(.secondary)
            }
        } else if outcome.applied {
            Text(outcome.automatic ? "Updated automatically at \(time)" : "Updated at \(time)").font(.title3.weight(.semibold))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview").font(.title3.weight(.semibold))
                Text("Nothing has changed yet. Made at \(time).").foregroundStyle(.secondary)
            }
        }
    }

    /// Shows at most this many names; the counts above are always complete.
    private let shown = 1000

    @ViewBuilder
    private func names(_ names: [String], title: String, symbol: String) -> some View {
        if !names.isEmpty {
            Fold(title: title, count: names.count, expanded: names.count <= 12) {
                ForEach(names.prefix(shown), id: \.self) { name in
                    Label {
                        Text(name).font(.path).textSelection(.enabled)
                    } icon: {
                        Image(systemName: symbol).foregroundStyle(Color.marigold)
                    }
                }
                if names.count > shown {
                    Text("and \((names.count - shown).formatted()) more").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    var highlight = false
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 96, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if highlight {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(Color.marigold)
                    .frame(width: 3)
            }
        }
    }
}

/// A list that folds away, lazily drawn because a first run can link thousands.
private struct Fold<Content: View>: View {
    let title: String
    let count: Int
    @State var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(title: String, count: Int, expanded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        _expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
