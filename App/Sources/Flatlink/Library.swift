import AppKit
import FlatlinkCore
import FlatlinkPairs
import Foundation
import Observation

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
    /// Saved entries this version can't read, saved back with the pairs so that they are never lost.
    @ObservationIgnored private var unreadable: [Data] = []

    private static let key = "pairs"
    /// Where saved pairs that can't be read at all are put aside, rather than saved over.
    private static let unreadableKey = "pairs.unreadable"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        let read = saved.flatMap(SavedPairs.init(decoding:))
        if let saved, read == nil { UserDefaults.standard.set(saved, forKey: Self.unreadableKey) }
        pairs = read?.pairs ?? []
        unreadable = read?.unreadable ?? []
        // A pair saved before its drive was recorded learns it now, if the drive is there.
        // Saved only then: a launch given its pairs as an argument must never write them over the saved ones.
        var learned = false
        for index in pairs.indices where pairs[index].sourceVolume == nil {
            guard let volume = volumeIdentity(of: pairs[index].source) else { continue }
            pairs[index].sourceVolume = volume
            learned = true
        }
        if learned { save() }
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
        // Forgotten before it is let go: with its run gone, nothing would end an update still due.
        runs[id]?.forget()
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
        for pair in pairs where pair.watched != nil && pair.isOnVolume(volume) {
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
        guard let data = try? SavedPairs(pairs: pairs, unreadable: unreadable).encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
