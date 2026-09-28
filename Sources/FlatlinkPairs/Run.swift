import FlatlinkCore
import Foundation
import Observation

/// What became of one preview or update, sorted for showing.
public struct Outcome: Sendable {
    public var summary: FlattenSummary
    public var applied: Bool
    /// Set off by the watcher rather than by a click.
    public var automatic = false
    public var date = Date()
    public var linked: [String] = []
    public var relinked: [String] = []
    public var pruned: [String] = []
    public var issues: [Issue] = []

    public struct Issue: Identifiable, Sendable {
        public var id: Int
        public var title: String
        public var detail: String
    }

    init(summary: FlattenSummary, events: [FlattenEvent], applied: Bool, automatic: Bool = false, source: String) {
        self.summary = summary
        self.applied = applied
        self.automatic = automatic
        func relative(_ path: String) -> String {
            path.hasPrefix(source + "/") ? String(path.dropFirst(source.count + 1)) : path
        }
        for event in events {
            let issue: (String, String)
            switch event {
            case .link(let name): linked.append(name); continue
            case .relink(let name): relinked.append(name); continue
            case .prune(let name): pruned.append(name); continue
            case .skipPointsElsewhere(let name):
                issue = (name, "A link with this name leads somewhere else. It was left alone; remove it if you don't need it.")
            case .skipRealFile(let name):
                issue = (name, "A file with this name is already in the link folder. It is never replaced; move it out to let the link in.")
            case .collision(let name, let src, let holder):
                issue = (relative(src), "Wants the link \(name), which belongs to \(relative(holder)). Rename one of them to bring it in.")
            case .unreadable(let path, let message):
                issue = (path, "This folder can't be read (\(message)). Its photos are missing until it can.")
            case .failed(let name, let message):
                issue = (name, message)
            }
            issues.append(Issue(id: issues.count, title: issue.0, detail: issue.1))
        }
    }

    public var isUpToDate: Bool { linked.isEmpty && relinked.isEmpty && pruned.isEmpty && issues.isEmpty }
    /// Changes still to make, when this was only a preview.
    public var pending: Int { applied ? 0 : linked.count + relinked.count + pruned.count }
}

/// Previews and updates for one pair, run away from the main thread.
@MainActor @Observable
public final class Run {
    public enum Phase {
        case idle
        case scanning(ScanProgress?)
        case finished(Outcome)
        case failed(String)
    }

    /// Whether this pair updates by itself.
    public enum Watch {
        case off
        case watching
        /// The source isn't there, which for a folder on an external drive usually means it's unplugged.
        case waitingForSource
    }

    public private(set) var phase: Phase = .idle
    public private(set) var watch: Watch = .off
    /// How long a source must be quiet before an update: an import copies photos one by one, and
    /// one update at its end is better than one per photo.
    public static let quietPeriod: Duration = .seconds(5)
    /// The plan behind the last preview, which Update carries out as it was shown.
    private var planned: (options: FlattenOptions, plan: FlattenPlan)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The pair as it is now, looked up when an automatic update starts rather than when it is asked for.
    private var current: (@MainActor () -> Pair?)?
    private var pendingUpdate: Task<Void, Never>?
    /// Photos arrived while a run was going: look again once it is done.
    private var anotherPass = false
    /// Keeps App Nap from stretching the quiet period while an update is due.
    private var activity: NSObjectProtocol?
    /// The last run started in each link folder, which the next run there waits for.
    private static var running: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    public init() {}

    public var isBusy: Bool {
        if case .scanning = phase { true } else { false }
    }

    public var outcome: Outcome? {
        if case .finished(let outcome) = phase { outcome } else { nil }
    }

    public func preview(_ pair: Pair) { start(pair, apply: false) }
    public func update(_ pair: Pair) { start(pair, apply: true) }

    /// Stops the run going now. An automatic update still due goes ahead.
    public func cancel() {
        interrupt()
        anotherPass = false
        if pendingUpdate == nil { endActivity() }
    }

    private func interrupt() {
        task?.cancel()
        task = nil
        generation += 1
        if isBusy { phase = .idle }
    }

    /// The folders or options changed: what was shown no longer describes them.
    public func reset() {
        cancel()
        planned = nil
        phase = .idle
    }

    public func forgetPlan() { planned = nil }

    // MARK: Updating by itself

    public func startWatching(_ current: @escaping @MainActor () -> Pair?) {
        self.current = current
        watch = .watching
        // Catch up with whatever was imported while nothing was watching.
        sourceChanged(after: .seconds(1))
    }

    public func stopWatching() {
        watch = .off
        current = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        anotherPass = false
        endActivity()
    }

    /// The pair is gone: nothing more runs for it, not even an update that was due, and App Nap is let be.
    public func forget() {
        stopWatching()
        cancel()
    }

    /// Whether App Nap is held off, as it is while an update is due or running.
    var isKeepingAwake: Bool { activity != nil }

    public func driveWentAway() {
        guard watch != .off else { return }
        pendingUpdate?.cancel()
        watch = .waitingForSource
        endActivity()
    }

    /// Something changed in the source: update once it has been quiet for a while.
    public func sourceChanged(after delay: Duration = Run.quietPeriod) {
        guard watch != .off else { return }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Updating links after photos were added"
            )
        }
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.updateByItself()
        }
    }

    private func updateByItself() {
        pendingUpdate = nil
        guard watch != .off, let pair = current?(), pair.isReady else { return endActivity() }
        if isBusy {
            anotherPass = true
            return
        }
        guard FileManager.default.fileExists(atPath: pair.source) else {
            watch = .waitingForSource
            return endActivity()
        }
        watch = .watching
        start(pair, apply: true, automatic: true)
    }

    private func finished() {
        if anotherPass, watch != .off {
            anotherPass = false
            sourceChanged(after: .seconds(1))
        } else if pendingUpdate == nil {
            endActivity()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Running

    private func start(_ pair: Pair, apply: Bool, automatic: Bool = false) {
        interrupt()
        let options = pair.options
        let reuse = apply && !automatic && planned?.options == options ? planned?.plan : nil
        let generation = generation
        let previous: Phase? = if case .scanning = phase { nil } else { phase }
        phase = .scanning(nil)

        // One run at a time in a link folder, whichever pair it is for: a run that is cancelled finishes
        // the change it is making, and two runs planned side by side would both make the same links.
        let folder = canonicalPath(options.dest)
        let before = Self.running[folder]?.task
        let job = Task.detached(priority: .userInitiated) { [weak self] () throws -> (FlattenPlan, Outcome) in
            await before?.value
            try Task.checkCancellation()
            let made = try reuse ?? FlatlinkCore.plan(options) { progress in
                Task { @MainActor in self?.progressed(progress, generation) }
            }
            try Task.checkCancellation()
            var events: [FlattenEvent] = []
            let summary = try carryOut(made, dryRun: !apply) { events.append($0) }
            let outcome = Outcome(summary: summary, events: events, applied: apply, automatic: automatic, source: options.source)
            return (made, outcome)
        }

        let token = UUID()
        Self.running[folder] = (token, Task {
            _ = await job.result
            if Self.running[folder]?.token == token { Self.running[folder] = nil }
        })

        task = Task {
            do {
                let (made, outcome) = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                guard generation == self.generation else { return }
                planned = apply ? nil : (options, made)
                phase = .finished(outcome)
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                if automatic, case FlattenError.sourceNotFolder = error {
                    // Unplugged while being looked through: wait for it, and keep showing the last result.
                    watch = .waitingForSource
                    if let previous { phase = previous } else { phase = .idle }
                } else if automatic, case FlattenError.sourceOnOtherDrive = error {
                    // Another drive where the photos' drive was: wait for the right one, and say why.
                    watch = .waitingForSource
                    phase = .failed(Self.message(for: error))
                } else {
                    phase = .failed(Self.message(for: error))
                }
            }
            finished()
        }
    }

    private func progressed(_ progress: ScanProgress, _ generation: Int) {
        guard generation == self.generation, isBusy else { return }
        phase = .scanning(progress)
    }

    public static func message(for error: Error) -> String {
        guard let error = error as? FlattenError else { return error.localizedDescription }
        switch error {
        case .sourceNotFolder(let path):
            return path.hasPrefix("/Volumes/")
                ? "The photo folder isn't there. Is its drive connected?"
                : "The photo folder isn't there: \(path)"
        case .sourceOnOtherDrive:
            return "The photo folder is on a different drive from the one it was chosen on, so nothing was changed. "
                + "If this is the right drive, choose the photo folder again."
        case .destIsSource:
            return "The link folder must be a different folder from the photos."
        case .destNotFolder(let path):
            return "The link folder can't be used: \(path) is not a folder."
        case .destNotWritable(let path):
            return "Flatlink can't write to the link folder \((path as NSString).abbreviatingWithTildeInPath). "
                + "Choose a link folder you can write to, on the same drive as the photos."
        case .pruneFoundNoImages:
            return "No photos were found in the photo folder, so nothing was pruned: that is what an unplugged "
                + "drive looks like. Is the drive connected, and is this the right folder?"
        case .pruneDriveNotMounted:
            return "The photo folder's drive isn't connected, so nothing was pruned: what is there now is a folder "
                + "left on this Mac where the drive was. Connect the drive and update again."
        }
    }
}
