import FlatlinkCore
import Foundation

/// A photo folder and the flat link folder made from it, with the options it is run with.
public struct Pair: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var source = "" {
        didSet { sourceVolume = volumeIdentity(of: source) }
    }
    /// The drive the source was chosen on, so that another drive mounted in its place is never taken for it.
    public var sourceVolume: String?
    public var dest = ""
    public var skipPairedJPEGs = false
    public var prune = false
    /// Update by itself when photos are added, moved or deleted in the source. Off for a new pair: the
    /// link folder was only suggested, and nothing is written to it until the user asks.
    public var watch = false

    public var name: String { source.isEmpty ? "New pair" : (source as NSString).lastPathComponent }
    public var destName: String { dest.isEmpty ? "" : (dest as NSString).lastPathComponent }
    public var isReady: Bool { !source.isEmpty && !dest.isEmpty }

    public var options: FlattenOptions {
        var options = FlattenOptions(source: source, dest: dest)
        options.skipPairedJPEGs = skipPairedJPEGs
        options.prune = prune
        options.sourceVolume = sourceVolume
        return options
    }

    public init(id: UUID = UUID(), source: String = "", dest: String = "") {
        self.id = id
        self.source = source
        self.dest = dest
        sourceVolume = volumeIdentity(of: source)
    }

    /// Keys added later may be missing from what an earlier version saved.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        sourceVolume = try c.decodeIfPresent(String.self, forKey: .sourceVolume)
        dest = try c.decode(String.self, forKey: .dest)
        skipPairedJPEGs = try c.decodeIfPresent(Bool.self, forKey: .skipPairedJPEGs) ?? false
        prune = try c.decodeIfPresent(Bool.self, forKey: .prune) ?? false
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? false
    }

    /// What a watcher looks at. The other options only matter to the runs it sets off.
    public var watched: WatchedFolders? {
        watch && isReady ? WatchedFolders(source: source, dest: dest) : nil
    }

    /// Whether the source is on the drive mounted at `volume`, the drive's top folder included.
    public func isOnVolume(_ volume: String) -> Bool {
        source == volume || source.hasPrefix(volume == "/" ? volume : volume + "/")
    }

    /// Where a link folder goes by default: beside the photos, so it travels with their drive. When the
    /// photos are a drive's top folder, beside them is /Volumes, which is not on the drive and can't be
    /// written to, so the link folder goes inside them instead; the scan never looks into it.
    public static func suggestedDest(for source: String) -> String {
        let parent = (source as NSString).deletingLastPathComponent
        let base = isTopOfDrive(source, parent: parent) ? source : parent
        return (base as NSString).appendingPathComponent("PhotoLab-All")
    }

    private static func isTopOfDrive(_ path: String, parent: String) -> Bool {
        // Asked of the path first, so that a drive that isn't mounted just now is known too.
        if parent == "/" || parent == "/Volumes" { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }
}

public struct WatchedFolders: Equatable, Sendable {
    public var source: String
    public var dest: String

    public init(source: String, dest: String) {
        self.source = source
        self.dest = dest
    }
}

/// The saved list of pairs, read back entry by entry so that one entry this version can't read (damaged,
/// or written by a newer version) never costs the rest. Such entries are kept as they were and saved back.
public struct SavedPairs {
    public var pairs: [Pair]
    public var unreadable: [Data]

    public init(pairs: [Pair] = [], unreadable: [Data] = []) {
        self.pairs = pairs
        self.unreadable = unreadable
    }

    /// Nil when `data` isn't a list at all: the caller keeps it aside rather than saving over it.
    public init?(decoding data: Data) {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        self.init()
        let decoder = JSONDecoder()
        for entry in entries {
            guard let entryData = try? JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed]) else { continue }
            if let pair = try? decoder.decode(Pair.self, from: entryData) {
                pairs.append(pair)
            } else {
                unreadable.append(entryData)
            }
        }
    }

    /// The pairs, followed by the entries that couldn't be read, as one list.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        let entries = try pairs.map { try encoder.encode($0) } + unreadable
        var data = Data("[".utf8)
        for (index, entry) in entries.enumerated() {
            if index > 0 { data.append(contentsOf: ",".utf8) }
            data.append(entry)
        }
        data.append(contentsOf: "]".utf8)
        return data
    }
}
