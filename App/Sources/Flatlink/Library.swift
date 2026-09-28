import AppKit
import FlatlinkCore
import Foundation
import Observation

/// A photo folder and the flat link folder made from it, with the options it is run with.
struct Pair: Codable, Identifiable, Hashable {
    var id = UUID()
    var source = ""
    var dest = ""
    var skipPairedJPEGs = false
    var prune = false
    /// Update by itself when photos are added, moved or deleted in the source.
    var watch = true

    var name: String { source.isEmpty ? "New pair" : (source as NSString).lastPathComponent }
    var destName: String { dest.isEmpty ? "" : (dest as NSString).lastPathComponent }
    var isReady: Bool { !source.isEmpty && !dest.isEmpty }

    var options: FlattenOptions {
        var options = FlattenOptions(source: source, dest: dest)
        options.skipPairedJPEGs = skipPairedJPEGs
        options.prune = prune
        return options
    }

    init(id: UUID = UUID(), source: String = "", dest: String = "") {
        self.id = id
        self.source = source
        self.dest = dest
    }

    /// Keys added later may be missing from what an earlier version saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        dest = try c.decode(String.self, forKey: .dest)
        skipPairedJPEGs = try c.decodeIfPresent(Bool.self, forKey: .skipPairedJPEGs) ?? false
        prune = try c.decodeIfPresent(Bool.self, forKey: .prune) ?? false
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? false
    }

    /// What a watcher looks at. The other options only matter to the runs it sets off.
    var watched: WatchedFolders? {
        watch && isReady ? WatchedFolders(source: source, dest: dest) : nil
    }

    /// Where a link folder goes by default: beside the photos, so it travels with their drive.
    static func suggestedDest(for source: String) -> String {
        ((source as NSString).deletingLastPathComponent as NSString).appendingPathComponent("PhotoLab-All")
    }
}

struct WatchedFolders: Equatable {
    var source: String
    var dest: String
}

/// The saved pairs, and what each is doing.
@MainActor @Observable
final class Library {
    var pairs: [Pair] {
        didSet {
            save()
            syncWatchers()
        }
    }
    private(set) var runs: [Pair.ID: Run] = [:]
    @ObservationIgnored private var watchers: [Pair.ID: (folders: WatchedFolders, watcher: SourceWatcher)] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let key = "pairs"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        pairs = saved.flatMap { try? JSONDecoder().decode([Pair].self, from: $0) } ?? []
        for pair in pairs { runs[pair.id] = Run() }
        syncWatchers()
        observeVolumes()
    }

    var isWatching: Bool { !watchers.isEmpty }

    func run(for id: Pair.ID) -> Run? { runs[id] }

    @discardableResult
    func add(source: String) -> Pair {
        let pair = Pair(source: source, dest: Pair.suggestedDest(for: source))
        runs[pair.id] = Run()
        pairs.append(pair)
        return pair
    }

    /// Forgets a pair. Nothing on disk is touched: its links and edits stay where they are.
    func remove(_ id: Pair.ID) {
        runs[id]?.cancel()
        runs[id] = nil
        pairs.removeAll { $0.id == id }
    }

    /// Photos may have been imported while the app was in the background, so a preview made before
    /// is not applied as it was: the next update looks at the folders again.
    func forgetPlans() {
        for run in runs.values { run.forgetPlan() }
    }

    /// Starts a watcher for every pair that wants one and stops the rest. A new watcher first catches up
    /// with whatever was imported while nothing was watching.
    private func syncWatchers() {
        let wanted = Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in pair.watched.map { (pair.id, $0) } })
        for (id, entry) in watchers where wanted[id] != entry.folders {
            entry.watcher.stop()
            watchers[id] = nil
            if wanted[id] == nil { runs[id]?.stopWatching() }
        }
        for (id, folders) in wanted where watchers[id] == nil {
            let watcher = SourceWatcher(FlattenOptions(source: folders.source, dest: folders.dest)) { [weak self] _ in
                Task { @MainActor in self?.runs[id]?.sourceChanged() }
            }
            watcher.start()
            watchers[id] = (folders, watcher)
            runs[id]?.startWatching { [weak self] in self?.pairs.first { $0.id == id } }
        }
    }

    /// FSEvents reports a source that comes back, but a drive being mounted is the surest sign, so the
    /// watchers below it start afresh and catch up.
    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated { self?.volumeChanged(volume, mounted: true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated { self?.volumeChanged(volume, mounted: false) }
        })
    }

    private func volumeChanged(_ volume: String?, mounted: Bool) {
        guard let volume else { return }
        for pair in pairs where pair.watched != nil && pair.source.hasPrefix(volume + "/") {
            if mounted {
                watchers[pair.id]?.watcher.stop()
                watchers[pair.id] = nil
            } else {
                runs[pair.id]?.driveWentAway()
            }
        }
        if mounted { syncWatchers() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pairs) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
