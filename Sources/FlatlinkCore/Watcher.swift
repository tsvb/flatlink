import CoreServices
import Foundation

/// What happened in a watched source.
public enum SourceChange: Equatable, Sendable {
    /// Images, or folders that may hold them, were added, removed or renamed.
    case images([String])
    /// The source itself appeared, went away or moved, a volume came or went below it, or so much
    /// changed that the system lost count. Only a full run can tell what that means for the links.
    case everything
}

/// Watches a source for the changes that call for another run, through FSEvents.
///
/// Only a change a run would act on is reported: an image added, removed or renamed, or a folder, which
/// may take images with it. Edits to an image, other files, hidden files, package contents, symlinks and
/// everything in the link folder are left out, so the links a run makes in a link folder inside the
/// source never set off another run.
public final class SourceWatcher: @unchecked Sendable {
    private let root: String
    private let dest: String
    private let extensions: Set<String>
    private let latency: TimeInterval
    private let onChange: @Sendable (SourceChange) -> Void
    /// Callbacks arrive here, and the stream is started and stopped here, so that a callback never
    /// runs while the stream is being torn down.
    private let queue = DispatchQueue(label: "flatlink.SourceWatcher")
    private var stream: FSEventStreamRef?
    /// Whether a folder is a package, as far as it has been asked. Only touched on `queue`.
    private var packages: [String: Bool] = [:]

    /// `latency` is how long FSEvents gathers events before handing them over. `onChange` is called on a
    /// private queue, and must not call `stop()` there.
    public init(_ options: FlattenOptions, latency: TimeInterval = 1, onChange: @escaping @Sendable (SourceChange) -> Void) {
        root = canonicalPath(options.source)
        dest = canonicalPath(options.dest)
        extensions = options.extensions
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching, from now on. The source need not exist yet: its drive may not be connected, and
    /// `.everything` is reported when it appears. Returns false if FSEvents can't watch the path.
    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.received(paths, Array(UnsafeBufferPointer(start: flags, count: count)))
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let made = FSEventStreamCreate(
                nil, callback, &context, [root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(made, queue)
            guard FSEventStreamStart(made) else {
                FSEventStreamInvalidate(made)
                FSEventStreamRelease(made)
                return false
            }
            stream = made
            return true
        }
    }

    /// Stops watching. No change is reported once this returns.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let wholesale = kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        var images: [String] = []
        for (path, flag) in zip(paths, flags) {
            if Int(flag) & wholesale != 0 {
                onChange(.everything)
                return
            }
            if isRelevant(path, flags: Int(flag)) { images.append(path) }
        }
        if !images.isEmpty { onChange(.images(images)) }
    }

    /// Whether a run would act on this event.
    func isRelevant(_ path: String, flags: Int) -> Bool {
        // A link may keep working after its image is edited in place; only a name coming or going matters.
        let naming = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
        guard flags & naming != 0, flags & kFSEventStreamEventFlagItemIsSymlink == 0 else { return false }
        guard isInside(path, root), path != dest, !isInside(path, dest) else { return false }

        let components = relativePath(path, below: root).split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        // Package contents are never linked: a Photos library inside the source changes all the time.
        var folder = root
        for component in components.dropLast() {
            folder += "/" + component
            if component.contains("."), isPackage(folder) { return false }
        }
        if flags & kFSEventStreamEventFlagItemIsDir != 0 { return true }
        return splitExtension(String(components.last ?? "")).map { extensions.contains($0.ext) } ?? false
    }

    private func isPackage(_ folder: String) -> Bool {
        if let known = packages[folder] { return known }
        let values = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey])
        let answer = values?.isPackage ?? false
        packages[folder] = answer
        return answer
    }
}
