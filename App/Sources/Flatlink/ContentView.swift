import FlatlinkPairs
import SwiftUI

struct ContentView: View {
    @Bindable var library: Library
    @Binding var selection: Pair.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.pairs) { pair in
                    PairRow(pair: pair, run: library.run(for: pair.id))
                        .tag(pair.id)
                        .contextMenu {
                            Button("Show Link Folder in Finder") { Panels.reveal(pair.dest) }
                                .disabled(!FileManager.default.fileExists(atPath: pair.dest))
                            Divider()
                            Button("Remove from List") { remove(pair.id) }
                        }
                }
            }
            .overlay {
                if library.pairs.isEmpty {
                    Text("No folders yet").foregroundStyle(.tertiary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: add) {
                    Label("Add Photo Folder", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let id = selection, let run = library.run(for: id) {
                PairView(pair: binding(for: id), run: run)
                    .id(id)
            } else {
                Welcome(hasPairs: !library.pairs.isEmpty, add: add)
            }
        }
        .onAppear {
            if selection == nil { selection = library.pairs.first?.id }
        }
    }

    private func add() {
        if let source = Panels.chooseSource() { selection = library.add(source: source).id }
    }

    private func remove(_ id: Pair.ID) {
        if selection == id { selection = nil }
        library.remove(id)
    }

    /// Looked up by id rather than by index, so that removing a pair can't leave a view holding a stale index.
    private func binding(for id: Pair.ID) -> Binding<Pair> {
        Binding {
            library.pairs.first { $0.id == id } ?? Pair(id: id)
        } set: { pair in
            if let index = library.pairs.firstIndex(where: { $0.id == id }) { library.pairs[index] = pair }
        }
    }
}

struct PairRow: View {
    let pair: Pair
    let run: Run?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(pair.name).lineLimit(1)
                if !pair.destName.isEmpty {
                    Text("→ \(pair.destName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if pair.watched != nil {
                Image(systemName: run?.watch == .waitingForSource ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(run?.watch == .waitingForSource ? "Waiting for the photo folder" : "Updates automatically")
            }
            status
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        switch run?.phase {
        case .scanning:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .finished(let outcome) where !outcome.issues.isEmpty:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .finished(let outcome) where outcome.pending > 0:
            Text(outcome.pending.formatted())
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.prussianDeep)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.marigold, in: .capsule)
        case .finished(let outcome) where outcome.applied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            EmptyView()
        }
    }
}

struct Welcome: View {
    let hasPairs: Bool
    let add: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("flatlink")
                    .font(.wordmark)
                    .foregroundStyle(.white)
                Text("Every photo in a folder tree,\nin one DxO PhotoLab grid.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(28)
            .frame(width: 380, alignment: .leading)
            .background(.card, in: .rect(cornerRadius: 18))

            if hasPairs {
                Text("Choose a folder on the left.").foregroundStyle(.secondary)
            } else {
                Text("PhotoLab shows only the photos at the top of a folder. Choose the folder that holds your photos, and Flatlink fills a flat folder with links to all of them.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Button("Choose a Photo Folder…", action: add)
                    .buttonStyle(MarigoldButtonStyle())
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
