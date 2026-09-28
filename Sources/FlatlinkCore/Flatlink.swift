import Foundation

/// File types the tool knows about. Extensions are compared lowercased.
public enum ImageTypes {
    public static let jpeg: Set<String> = ["jpg", "jpeg", "jpe"]
    public static let raw: Set<String> = [
        "dng", "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "orf",
        "raf", "rw2", "rwl", "pef", "srw", "3fr", "fff", "iiq", "erf", "mef",
        "mos", "mrw", "x3f", "gpr",
    ]
    public static let all: Set<String> = jpeg.union(["tif", "tiff", "heic", "heif", "png"]).union(raw)
}

public struct FlattenOptions: Equatable, Sendable {
    public var source: String
    public var dest: String
    public var dryRun = false
    public var prune = false
    public var extensions: Set<String> = ImageTypes.all
    public var skipPairedJPEGs = false
    /// The drive the source was chosen on, as `volumeIdentity(of:)` told it. When set, a source on any
    /// other drive is refused: one mounted where the source's drive was would otherwise pass for it, and
    /// every link into the missing drive would look like a photo that was deleted.
    public var sourceVolume: String?

    public init(source: String, dest: String) {
        self.source = source
        self.dest = dest
    }
}

public struct FlattenSummary: Equatable, Sendable {
    /// `found` is the number of images that want a link; the other counts say what became of them.
    public var found = 0, created = 0, kept = 0, relinked = 0, skipped = 0, pruned = 0, paired = 0, failed = 0
    public var dest = ""
}

public enum FlattenEvent: Hashable, Sendable {
    case link(String)
    case relink(String)
    case skipPointsElsewhere(String)
    case skipRealFile(String)
    /// Two images have the same link name: `source` is left out, the link belongs to `holder`.
    case collision(name: String, source: String, holder: String)
    case prune(String)
    case unreadable(String, String)
    case failed(String, String)
}

public enum FlattenError: Error, Equatable, CustomStringConvertible {
    case sourceNotFolder(String)
    case sourceOnOtherDrive(String)
    case destIsSource
    case destNotFolder(String)
    case destNotWritable(String)
    case pruneFoundNoImages(String)

    public var description: String {
        switch self {
        case .sourceNotFolder(let path): "source is not a folder: \(path)"
        case .sourceOnOtherDrive(let path): "source is not on the drive it was chosen on: \(path)"
        case .destIsSource: "dest must differ from source"
        case .destNotFolder(let path): "dest can't be used, this is not a folder: \(path)"
        case .destNotWritable(let path): "dest can't be written to: \(path)"
        case .pruneFoundNoImages(let path):
            "no images found under \(path), so --prune would remove every link into it; nothing was removed. "
                + "Is the drive connected, and is this the right folder?"
        }
    }
}

/// Link names encode the path below the source: `2024/Iceland/IMG_0001.CR3` → `2024__Iceland__IMG_0001.CR3`.
public let linkSeparator = "__"

/// The longest file name a folder holds: 255 bytes, or on Mac OS Extended 255 UTF-16 units.
let longestName = 255

/// Fills `dest` with one symlink per image under `source`. Never modifies anything but symlinks in `dest`.
public func flatten(_ options: FlattenOptions, report: (FlattenEvent) -> Void = { _ in }) throws -> FlattenSummary {
    try carryOut(plan(options), dryRun: options.dryRun, report: report)
}

/// What a run does about one image or one link.
enum Step: Sendable {
    case keep
    case link(String, to: String)
    /// `from` is where the link led when the plan was made; it is changed only while it still does.
    case relink(String, to: String, from: String)
    case prune(String, from: String)
    case skip(FlattenEvent)
    case fail(FlattenEvent)
}

/// Everything a run will do. Carry it out with `carryOut(_:dryRun:report:)`: a dry run to see it, and then
/// the same plan for real, so that what is shown is what is done.
public struct FlattenPlan: Sendable {
    public var dest: String
    /// Images that want a link, and JPEGs left out because a RAW of the same name is beside them.
    public var found = 0, paired = 0
    var steps: [Step] = []
}

/// How far the walk through the source has got.
public struct ScanProgress: Equatable, Sendable {
    /// Files and folders seen so far.
    public var items: Int
    /// The folder the walk is in.
    public var folder: String
}

/// Decides everything a run will do, changing nothing, so a dry run and a real run can't disagree.
///
/// `progress` is called now and then while the source is walked. Inside a task that is cancelled, this
/// throws `CancellationError`.
public func plan(_ options: FlattenOptions, progress: (ScanProgress) -> Void = { _ in }) throws -> FlattenPlan {
    let fm = FileManager.default
    // An empty path would mean the current folder.
    guard !options.source.isEmpty else { throw FlattenError.sourceNotFolder("") }
    guard !options.dest.isEmpty else { throw FlattenError.destNotFolder("") }
    let root = canonicalPath(options.source)
    let dest = canonicalPath(options.dest)

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
        throw FlattenError.sourceNotFolder(root)
    }
    if let expected = options.sourceVolume, volumeIdentity(of: root) != expected {
        throw FlattenError.sourceOnOtherDrive(root)
    }
    guard dest != root else { throw FlattenError.destIsSource }

    // The folder that decides what dest can hold: dest, or while it is missing the nearest one above it.
    var anchor = dest
    while !fm.fileExists(atPath: anchor, isDirectory: &isDir) {
        // Something that is there but leads nowhere: a broken link.
        guard (try? fm.attributesOfItem(atPath: anchor)) == nil else { throw FlattenError.destNotFolder(anchor) }
        anchor = (anchor as NSString).deletingLastPathComponent
    }
    guard isDir.boolValue else { throw FlattenError.destNotFolder(anchor) }
    let volume = Volume(of: anchor)

    let scan = try scanImages(root: root, dest: dest, options: options, progress: progress)
    var plan = FlattenPlan(dest: dest, found: scan.images.count, paired: scan.paired)
    plan.steps = scan.unreadable.map { .fail(.unreadable($0.path, $0.message)) }

    // Images that share a link name, in the order of the first of them.
    typealias Image = (name: String, src: String, relative: String)
    var rivalries: [[Image]] = []
    var wanted: [String: Int] = [:]
    for src in scan.images {
        let relative = String(src.dropFirst(root.count + 1))
        let name = relative.split(separator: "/").joined(separator: linkSeparator)
        if let known = wanted[volume.key(name)] {
            rivalries[known].append((name, src, relative))
        } else {
            wanted[volume.key(name)] = rivalries.count
            rivalries.append([(name, src, relative)])
        }
    }

    for rivals in rivalries {
        try Task.checkCancellation()
        // The link belongs to the image it already leads to, or else to the first one.
        var holder = rivals[0]
        let link = dest + "/" + holder.name
        let step: Step

        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            if let owner = rivals.first(where: { target == $0.src || isSameFile(link, $0.src) }) {
                holder = owner
                step = .keep
            } else if targetIsGone(link),
                let heir = rivals.first(where: { target.hasSuffix("/" + $0.relative) }) ?? (isInside(target, root) ? holder : nil)
            {
                // A link of ours left dangling: the source was moved or renamed, or its drive mounts
                // elsewhere. Repointing it keeps the link name, and so the edits in its .dop.
                holder = heir
                step = .relink(heir.name, to: heir.src, from: target)
            } else {
                step = .skip(.skipPointsElsewhere(holder.name))
            }
        } else if (try? fm.attributesOfItem(atPath: link)) != nil {
            step = .skip(.skipRealFile(holder.name))
        } else if volume.length(of: holder.name) > longestName {
            let reason = "the link name would be \(volume.length(of: holder.name)) long and a file name holds "
                + "\(longestName); shorten the names of the folders above this photo"
            step = .fail(.failed(holder.name, reason))
        } else {
            step = .link(holder.name, to: holder.src)
        }

        plan.steps.append(step)
        for rival in rivals where rival.src != holder.src {
            plan.steps.append(.skip(.collision(name: rival.name, source: rival.src, holder: holder.src)))
        }
    }

    if options.prune, anchor == dest {
        do {
            // Only links into this source whose original is gone. A link into another folder or drive
            // is not ours to judge, and an original that can't be reached is not a deleted one.
            let stale = try fm.contentsOfDirectory(atPath: dest).sorted().compactMap { name -> (String, String)? in
                let link = dest + "/" + name
                guard wanted[volume.key(name)] == nil, let target = try? fm.destinationOfSymbolicLink(atPath: link) else {
                    return nil
                }
                return isInside(target, root) && targetIsGone(link) ? (name, target) : nil
            }
            // A source without images but with links into it looks like the empty mount point of an
            // unplugged drive, not like a library whose photos were all deleted.
            guard stale.isEmpty || !rivalries.isEmpty else { throw FlattenError.pruneFoundNoImages(root) }
            plan.steps += stale.map { .prune($0, from: $1) }
        } catch let error as FlattenError {
            throw error
        } catch {
            plan.steps.append(.fail(.unreadable(dest, error.localizedDescription)))
        }
    }

    let writes = plan.steps.contains { step in
        switch step {
        case .link, .relink, .prune: true
        case .keep, .skip, .fail: false
        }
    }
    guard access(anchor, W_OK) == 0 || (anchor == dest && !writes) else { throw FlattenError.destNotWritable(dest) }
    return plan
}

/// Makes the changes in `plan`, or with `dryRun` only reports them. A change that fails is reported as
/// `.failed` and counted; the rest go ahead.
public func carryOut(_ plan: FlattenPlan, dryRun: Bool, report: (FlattenEvent) -> Void = { _ in }) throws -> FlattenSummary {
    let fm = FileManager.default
    if !dryRun {
        try fm.createDirectory(atPath: plan.dest, withIntermediateDirectories: true)
    }
    var summary = FlattenSummary(found: plan.found, paired: plan.paired, dest: plan.dest)

    func change(_ name: String, _ event: FlattenEvent, _ count: WritableKeyPath<FlattenSummary, Int>, _ work: () throws -> Void) {
        do {
            if !dryRun { try work() }
            report(event)
            summary[keyPath: count] += 1
        } catch {
            report(.failed(name, error.localizedDescription))
            summary.failed += 1
        }
    }

    for step in plan.steps {
        switch step {
        case .keep:
            summary.kept += 1
        case .link(let name, let src):
            change(name, .link(name), \.created) {
                try fm.createSymbolicLink(atPath: plan.dest + "/" + name, withDestinationPath: src)
            }
        case .relink(let name, let src, let old):
            change(name, .relink(name), \.relinked) {
                try checkUnchanged(plan.dest + "/" + name, leadsTo: old)
                try replaceLink(at: plan.dest + "/" + name, target: src)
            }
        case .prune(let name, let old):
            change(name, .prune(name), \.pruned) {
                try checkUnchanged(plan.dest + "/" + name, leadsTo: old)
                // unlink, not removeItem: it can never remove a folder.
                guard unlink(plan.dest + "/" + name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        case .skip(let event):
            report(event)
            summary.skipped += 1
        case .fail(let event):
            report(event)
            summary.failed += 1
        }
    }
    return summary
}

/// How the volume holding a folder tells file names apart and measures them.
struct Volume {
    var caseSensitive = false
    var countsUTF16 = false

    init(of folder: String) {
        let values = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
        var info = statfs()
        if statfs(folder, &info) == 0 {
            let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            countsUTF16 = type == "hfs"
        }
    }

    /// Equal for two names that can't both be in one folder. Strings already compare equal whichever
    /// way their accents are composed.
    func key(_ name: String) -> String {
        caseSensitive ? name : name.lowercased()
    }

    /// Names are stored with their accents decomposed.
    func length(of name: String) -> Int {
        let stored = name.decomposedStringWithCanonicalMapping
        return countsUTF16 ? stored.utf16.count : stored.utf8.count
    }
}

/// The drive that holds `path`, told apart from any other drive that may be mounted in the same place.
/// Nil for the startup drive, which nothing can take the place of, and for a drive with no UUID.
public func volumeIdentity(of path: String) -> String? {
    let keys: Set<URLResourceKey> = [.volumeIsRootFileSystemKey, .volumeUUIDStringKey]
    guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
          values.volumeIsRootFileSystem == false
    else { return nil }
    return values.volumeUUIDString
}

/// Whether the file a link points at is gone. Any failure other than "no such file" — no permission,
/// an I/O error — means it can't be reached, not that it was deleted.
func targetIsGone(_ link: String) -> Bool {
    var info = stat()
    guard stat(link, &info) != 0 else { return false }
    return errno == ENOENT || errno == ENOTDIR
}

/// Whether two paths lead to the same file, however they are spelled.
func isSameFile(_ a: String, _ b: String) -> Bool {
    var x = stat(), y = stat()
    return stat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
}

func isInside(_ path: String, _ folder: String) -> Bool {
    path.hasPrefix(folder == "/" ? folder : folder + "/")
}

/// The name no longer holds the link a plan was made from: a file may have been put in its place.
struct ChangedSincePlanned: LocalizedError {
    var errorDescription: String? {
        "it changed after the plan was made, so it was left alone; run again to see what it is now"
    }
}

/// Throws unless `link` is still a symlink leading to `target`, so that a plan made a while ago never
/// replaces or removes anything but the link it was made for.
func checkUnchanged(_ link: String, leadsTo target: String) throws {
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target else {
        throw ChangedSincePlanned()
    }
}

/// Points an existing link at `target` in one step, so a failure never leaves the name without a link.
func replaceLink(at link: String, target: String) throws {
    let temp = (link as NSString).deletingLastPathComponent + "/.flatlink-" + UUID().uuidString
    try FileManager.default.createSymbolicLink(atPath: temp, withDestinationPath: target)
    guard rename(temp, link) == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        unlink(temp)
        throw POSIXError(code)
    }
}

struct Scan {
    /// Absolute paths of the images to link, sorted.
    var images: [String] = []
    var paired = 0
    var unreadable: [(path: String, message: String)] = []
}

func scanImages(
    root: String, dest: String, options: FlattenOptions, progress: (ScanProgress) -> Void = { _ in }
) throws -> Scan {
    var scan = Scan()
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
    // Recursive on purpose — the opposite of PhotoLab's SkipsSubdirectoryDescendants — but, like
    // PhotoLab, skipping hidden files and package contents.
    guard let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root, isDirectory: true),
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        // Carry on past a folder that can't be read, but say so: its images will be missing.
        errorHandler: { url, error in
            scan.unreadable.append((url.path, error.localizedDescription))
            return true
        }
    ) else {
        scan.unreadable.append((root, "the folder can't be listed"))
        return scan
    }

    var filesByFolder: [String: [String]] = [:]
    var seen = 0
    for case let url as URL in walker {
        seen += 1
        if seen % 256 == 0 {
            try Task.checkCancellation()
            progress(ScanProgress(items: seen, folder: url.deletingLastPathComponent().path))
        }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: Set(keys)) } catch {
            scan.unreadable.append((url.path, error.localizedDescription))
            continue
        }
        // Symlinks are skipped so an earlier flat folder inside the tree isn't linked again.
        if values.isSymbolicLink == true { continue }
        if values.isDirectory == true {
            if url.path == dest { walker.skipDescendants() }
            continue
        }
        guard values.isRegularFile == true else { continue }
        filesByFolder[url.deletingLastPathComponent().path, default: []].append(url.lastPathComponent)
    }

    for (folder, names) in filesByFolder {
        // A camera JPEG is "paired" when a RAW with the same stem is in the same folder.
        let rawStems: Set<String> = options.skipPairedJPEGs
            ? Set(names.compactMap { name in splitExtension(name).flatMap { ImageTypes.raw.contains($0.ext) ? $0.stem : nil } })
            : []
        for name in names {
            guard let (stem, ext) = splitExtension(name), options.extensions.contains(ext) else { continue }
            if ImageTypes.jpeg.contains(ext), rawStems.contains(stem) {
                scan.paired += 1
                continue
            }
            scan.images.append(folder + "/" + name)
        }
    }
    scan.images.sort()
    scan.unreadable.sort { $0.path < $1.path }
    return scan
}

/// Lowercased stem and extension, or nil when the name has no extension.
func splitExtension(_ name: String) -> (stem: String, ext: String)? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return (name[..<dot].lowercased(), name[name.index(after: dot)...].lowercased())
}

/// Absolute path with symlinks resolved as far as the path exists (like Python's `Path.resolve()`).
/// Foundation's `resolvingSymlinksInPath` is avoided: it strips `/private` and leaves missing paths alone.
public func canonicalPath(_ path: String, relativeTo directory: String = FileManager.default.currentDirectoryPath) -> String {
    var absolute = (path as NSString).expandingTildeInPath
    if !absolute.hasPrefix("/") {
        absolute = directory + "/" + absolute
    }
    var existing = (absolute as NSString).standardizingPath
    var missing: [String] = []
    var resolved = realpath(existing, nil)
    while resolved == nil, existing != "/" {
        missing.insert((existing as NSString).lastPathComponent, at: 0)
        existing = (existing as NSString).deletingLastPathComponent
        resolved = realpath(existing, nil)
    }
    guard let resolved else { return (absolute as NSString).standardizingPath }
    defer { free(resolved) }
    let base = String(cString: resolved)
    return missing.isEmpty ? base : (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
}
