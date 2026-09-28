import FlatlinkPairs
import SwiftUI

struct PairView: View {
    @Binding var pair: Pair
    let run: Run
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                card
                options
                Divider()
                RunView(pair: pair, run: run)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(pair.name)
        .navigationSubtitle(pair.destName.isEmpty ? "" : "→ \(pair.destName)")
        .toolbar {
            ToolbarItemGroup {
                Button { Panels.reveal(pair.dest) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the link folder in Finder")
                .disabled(!FileManager.default.fileExists(atPath: pair.dest))

                Button { Panels.openInPhotoLab(pair.dest) } label: {
                    Label("Open in PhotoLab", systemImage: "photo.on.rectangle.angled")
                }
                .labelStyle(.titleAndIcon)
                .help(Panels.photoLab == nil ? "DxO PhotoLab isn't installed" : "Open the link folder in DxO PhotoLab")
                .disabled(Panels.photoLab == nil || !FileManager.default.fileExists(atPath: pair.dest))
            }
        }
        // Anything shown was worked out for the folders and options as they were.
        .onChange(of: pair) { run.reset() }
        .onChange(of: pair.source) {
            if pair.dest.isEmpty, !pair.source.isEmpty { pair.dest = Pair.suggestedDest(for: pair.source) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                FolderWell(role: .source, path: $pair.source, exists: exists(pair.source))
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.marigold)
                FolderWell(role: .dest, path: $pair.dest, exists: exists(pair.dest))
            }
            HStack(spacing: 10) {
                Toggle(isOn: $pair.watch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update automatically")
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Text(watchStatus)
                            .font(.caption)
                            .foregroundStyle(run.watch == .waitingForSource ? Color.marigold : Color.paleBlue.opacity(0.85))
                        // Watching only lasts as long as the app runs; offer the way to keep it going.
                        if run.watch != .off, !loginItem.isOn {
                            Button("Open at login to keep watching after a restart") { loginItem.set(true) }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.marigold)
                                .help("Flatlink opens with its window closed when you log in. Change this in Settings (⌘,).")
                        }
                    }
                    // A fixed width, so that the switch stays put while the status beside it changes.
                    .frame(width: 290, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("When photos are added, moved or deleted in the photo folder, update the links a few seconds later.")
                Spacer()
                if run.isBusy {
                    Button("Cancel") { run.cancel() }
                        .buttonStyle(CardButtonStyle())
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Preview") { run.preview(pair) }
                        .buttonStyle(CardButtonStyle())
                        .keyboardShortcut("r")
                        .help("See what would change, without changing anything (⌘R)")
                    Button(updateTitle) { run.update(pair) }
                        .buttonStyle(MarigoldButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Link new photos now (⌘↩)")
                }
            }
            .disabled(!pair.isReady)
        }
        .padding(20)
        .background(.card, in: .rect(cornerRadius: 16))
    }

    /// Checked each time the card is drawn, which includes after every run: an update makes the link
    /// folder, and a drive comes and goes.
    private func exists(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private var updateTitle: String {
        if let outcome = run.outcome, outcome.pending > 0 {
            "Make \(outcome.pending.formatted()) \(outcome.pending == 1 ? "Change" : "Changes")"
        } else {
            "Update Links"
        }
    }

    private var watchStatus: String {
        if !pair.isReady { return "Choose both folders to begin." }
        switch run.watch {
        case .off: return "Off. Update Links after each import."
        case .watching: return "Watching for new photos, even with this window closed."
        case .waitingForSource:
            return pair.source.hasPrefix("/Volumes/")
                ? "Waiting for the drive to be connected."
                : "Waiting for the photo folder to come back."
        }
    }

    private var options: some View {
        HStack(alignment: .top, spacing: 28) {
            Toggle(isOn: $pair.skipPairedJPEGs) {
                OptionLabel(
                    title: "Skip paired JPEGs",
                    detail: "Shoot RAW+JPEG? Leave out each JPEG that has a RAW of the same name beside it, so every shot shows once."
                )
            }
            Toggle(isOn: $pair.prune) {
                OptionLabel(
                    title: "Remove links to deleted photos",
                    detail: "Only links into this photo folder whose original is gone, or is a JPEG skipped beside its RAW. Your edits (.dop files) are never removed."
                )
            }
        }
        .toggleStyle(.checkbox)
        .disabled(run.isBusy)
    }
}

private struct OptionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of the two folders, chosen with a panel or dropped from Finder.
struct FolderWell: View {
    enum Role { case source, dest }

    let role: Role
    @Binding var path: String
    let exists: Bool
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role == .source ? "PHOTOS" : "LINK FOLDER")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(role == .source ? Color.paleBlue : Color.marigold)

            HStack(spacing: 10) {
                Image(systemName: role == .source ? "folder.fill" : "link")
                    .font(.title2)
                    .foregroundStyle(role == .source ? Color.white : Color.marigold)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path.isEmpty ? "Not chosen" : (path as NSString).lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(path.isEmpty ? 0.5 : 1))
                        .lineLimit(1)
                    Text(path.isEmpty ? "Drop a folder here" : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.paleBlue.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 12) {
                Button("Choose…") {
                    let chosen = role == .source ? Panels.chooseSource(startingAt: path) : Panels.chooseDest(startingAt: path)
                    if let chosen { path = chosen }
                }
                if exists {
                    Button("Show in Finder") { Panels.reveal(path) }
                }
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .foregroundStyle(role == .source ? Color.marigold : Color.paleBlue.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(isTargeted ? 0.16 : 0.07), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                isTargeted ? Color.marigold : Color.white.opacity(0.18),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: path.isEmpty ? [5, 4] : [])
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            var isDir: ObjCBool = false
            guard let url = urls.first, url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { return false }
            path = url.path
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var note: String? {
        guard !path.isEmpty, !exists else { return nil }
        // A folder on a drive that isn't mounted: /Volumes/Name is missing too.
        let components = (path as NSString).pathComponents
        if components.count > 2, components[1] == "Volumes",
           !FileManager.default.fileExists(atPath: "/Volumes/" + components[2]) {
            return "Drive not connected?"
        }
        switch role {
        case .source: return "Not found"
        case .dest: return "Made on first update"
        }
    }
}
