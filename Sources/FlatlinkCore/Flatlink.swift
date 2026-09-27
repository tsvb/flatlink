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

public struct FlattenOptions: Sendable {
    public var source: String
    public var dest: String
    public var dryRun = false
    public var prune = false
    public var extensions: Set<String> = ImageTypes.all
    public var skipPairedJPEGs = false

    public init(source: String, dest: String) {
        self.source = source
        self.dest = dest
    }
}

public struct FlattenSummary: Equatable, Sendable {
    public var created = 0, kept = 0, skipped = 0, pruned = 0, paired = 0, failed = 0
    public var dest = ""
}

public enum FlattenEvent: Hashable, Sendable {
    case link(String)
    case skipPointsElsewhere(String)
    case skipRealFile(String)
    case prune(String)
    case failed(String, String)
}

public enum FlattenError: Error, Equatable, CustomStringConvertible {
    case sourceNotFolder(String)
    case destIsSource

    public var description: String {
        switch self {
        case .sourceNotFolder(let path): "source is not a folder: \(path)"
        case .destIsSource: "dest must differ from source"
        }
    }
}

/// Link names encode the path below the source: `2024/Iceland/IMG_0001.CR3` → `2024__Iceland__IMG_0001.CR3`.
public let linkSeparator = "__"

/// Fills `dest` with one symlink per image under `source`. Never modifies anything but symlinks in `dest`.
public func flatten(_ options: FlattenOptions, report: (FlattenEvent) -> Void = { _ in }) throws -> FlattenSummary {
    let fm = FileManager.default
    let root = canonicalPath(options.source)
    let dest = canonicalPath(options.dest)

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
        throw FlattenError.sourceNotFolder(root)
    }
    guard dest != root else { throw FlattenError.destIsSource }
    if !options.dryRun {
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
    }

    var summary = FlattenSummary(dest: dest)
    var wanted = Set<String>()

    for src in scanImages(root: root, dest: dest, options: options, paired: &summary.paired) {
        let name = src.dropFirst(root.count + 1).split(separator: "/").joined(separator: linkSeparator)
        wanted.insert(name)
        let link = dest + "/" + name

        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            if target == src {
                summary.kept += 1
            } else {
                report(.skipPointsElsewhere(name))
                summary.skipped += 1
            }
        } else if (try? fm.attributesOfItem(atPath: link)) != nil {
            report(.skipRealFile(name))
            summary.skipped += 1
        } else if options.dryRun {
            report(.link(name))
            summary.created += 1
        } else {
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: src)
                report(.link(name))
                summary.created += 1
            } catch {
                report(.failed(name, error.localizedDescription))
                summary.failed += 1
            }
        }
    }

    if options.prune, let entries = try? fm.contentsOfDirectory(atPath: dest) {
        for name in entries.sorted() where !wanted.contains(name) {
            let link = dest + "/" + name
            // Only links whose target is gone; fileExists follows the link.
            guard (try? fm.destinationOfSymbolicLink(atPath: link)) != nil, !fm.fileExists(atPath: link) else { continue }
            report(.prune(name))
            if !options.dryRun {
                do { try fm.removeItem(atPath: link) } catch {
                    report(.failed(name, error.localizedDescription))
                    summary.failed += 1
                    continue
                }
            }
            summary.pruned += 1
        }
    }
    return summary
}

/// Absolute paths of the images to link, sorted by link name.
func scanImages(root: String, dest: String, options: FlattenOptions, paired: inout Int) -> [String] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
    // Recursive on purpose — the opposite of PhotoLab's SkipsSubdirectoryDescendants — but, like
    // PhotoLab, skipping hidden files and package contents.
    guard let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root, isDirectory: true),
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    var filesByFolder: [String: [String]] = [:]
    for case let url as URL in walker {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        // Symlinks are skipped so an earlier flat folder inside the tree isn't linked again.
        if values.isSymbolicLink == true { continue }
        if values.isDirectory == true {
            if url.path == dest { walker.skipDescendants() }
            continue
        }
        guard values.isRegularFile == true else { continue }
        filesByFolder[url.deletingLastPathComponent().path, default: []].append(url.lastPathComponent)
    }

    var images: [String] = []
    for (folder, names) in filesByFolder {
        // A camera JPEG is "paired" when a RAW with the same stem is in the same folder.
        let rawStems: Set<String> = options.skipPairedJPEGs
            ? Set(names.compactMap { name in splitExtension(name).flatMap { ImageTypes.raw.contains($0.ext) ? $0.stem : nil } })
            : []
        for name in names {
            guard let (stem, ext) = splitExtension(name), options.extensions.contains(ext) else { continue }
            if ImageTypes.jpeg.contains(ext), rawStems.contains(stem) {
                paired += 1
                continue
            }
            images.append(folder + "/" + name)
        }
    }
    return images.sorted()
}

/// Lowercased stem and extension, or nil when the name has no extension.
func splitExtension(_ name: String) -> (stem: String, ext: String)? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return (name[..<dot].lowercased(), name[name.index(after: dot)...].lowercased())
}

/// Absolute path with symlinks resolved as far as the path exists (like Python's `Path.resolve()`).
/// Foundation's `resolvingSymlinksInPath` is avoided: it strips `/private` and leaves missing paths alone.
public func canonicalPath(_ path: String) -> String {
    var absolute = (path as NSString).expandingTildeInPath
    if !absolute.hasPrefix("/") {
        absolute = FileManager.default.currentDirectoryPath + "/" + absolute
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
