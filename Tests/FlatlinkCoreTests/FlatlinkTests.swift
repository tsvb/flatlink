import Foundation
import Testing
@testable import FlatlinkCore

/// A throwaway folder tree under the temporary directory, removed when the test ends.
final class Tree {
    let root: String
    let fm = FileManager.default

    init() throws {
        root = canonicalPath(NSTemporaryDirectory() + "flatten-" + UUID().uuidString)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(atPath: root) }

    func touch(_ paths: String...) throws {
        for path in paths {
            let full = root + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            #expect(fm.createFile(atPath: full, contents: Data()))
        }
    }

    func links(in folder: String) -> [String: String] {
        let dir = root + "/" + folder
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            (try? fm.destinationOfSymbolicLink(atPath: dir + "/" + name)).map { (name, $0) }
        })
    }

    func run(_ source: String = "src", _ dest: String = "flat", configure: (inout FlattenOptions) -> Void = { _ in })
        throws -> (FlattenSummary, [FlattenEvent])
    {
        var options = FlattenOptions(source: root + "/" + source, dest: root + "/" + dest)
        configure(&options)
        var events: [FlattenEvent] = []
        let summary = try flatten(options) { events.append($0) }
        return (summary, events)
    }
}

@Test func linksEveryImageWithPathEncodedNames() throws {
    let t = try Tree()
    try t.touch("src/top.JPG", "src/2024/Iceland/IMG_0001.CR3", "src/2024/Iceland/notes.txt", "src/Misc/scan.tiff")
    let (summary, _) = try t.run()
    #expect(summary.created == 3)
    #expect(t.links(in: "flat") == [
        "top.JPG": t.root + "/src/top.JPG",
        "2024__Iceland__IMG_0001.CR3": t.root + "/src/2024/Iceland/IMG_0001.CR3",
        "Misc__scan.tiff": t.root + "/src/Misc/scan.tiff",
    ])
}

@Test func skipsHiddenFilesPackageContentsAndExtensionlessNames() throws {
    let t = try Tree()
    try t.touch("src/.hidden.jpg", "src/.dir/x.jpg", "src/Some.app/Contents/icon.png", "src/noext", "src/ok.jpg")
    let (summary, _) = try t.run()
    #expect(summary.created == 1)
    #expect(Array(t.links(in: "flat").keys) == ["ok.jpg"])
}

@Test func neverLinksLinksSoAnEarlierFlatFolderInsideTheTreeIsIgnored() throws {
    let t = try Tree()
    try t.touch("src/a/one.jpg")
    _ = try t.run("src", "src/_flat")          // dest inside the source
    let (summary, _) = try t.run("src", "src/_flat")
    #expect(summary.created == 0 && summary.kept == 1)
    let (other, _) = try t.run("src", "flat")  // the _flat links must not be linked again
    #expect(other.created == 1)
    #expect(Array(t.links(in: "flat").keys) == ["a__one.jpg"])
}

@Test func rerunIsIdempotent() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/b/c.dng")
    _ = try t.run()
    let (summary, events) = try t.run()
    #expect(summary.created == 0 && summary.kept == 2)
    #expect(events.isEmpty)
}

@Test func dryRunChangesNothing() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    let (summary, events) = try t.run { $0.dryRun = true }
    #expect(summary.created == 1 && events == [.link("a.jpg")])
    #expect(!t.fm.fileExists(atPath: t.root + "/flat"))
}

@Test func pruneRemovesOnlyLinksWhoseOriginalIsGone() throws {
    let t = try Tree()
    try t.touch("src/keep.jpg", "src/gone.jpg", "flat/real-file.txt")
    _ = try t.run()
    try t.fm.removeItem(atPath: t.root + "/src/gone.jpg")
    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.pruned == 1 && events == [.prune("gone.jpg")])
    #expect(Array(t.links(in: "flat").keys) == ["keep.jpg"])
    #expect(t.fm.fileExists(atPath: t.root + "/flat/real-file.txt"))
}

@Test func pruneKeepsPhotoLabSidecarsWrittenBesideLinks() throws {
    // PhotoLab writes <link name>.dop beside the link, so edits live in the link folder.
    let t = try Tree()
    try t.touch("src/day/A.RAF", "src/day/B.RAF")
    _ = try t.run()
    try t.touch("flat/day__A.RAF.dop", "flat/day__B.RAF.dop")
    try t.fm.removeItem(atPath: t.root + "/src/day/A.RAF")
    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.pruned == 1 && summary.kept == 1 && events == [.prune("day__A.RAF")])
    #expect(t.fm.fileExists(atPath: t.root + "/flat/day__A.RAF.dop"))
    #expect(t.fm.fileExists(atPath: t.root + "/flat/day__B.RAF.dop"))
}

@Test func neverReplacesARealFileOrAForeignLink() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/b.jpg", "flat/a.jpg", "elsewhere.jpg")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/b.jpg", withDestinationPath: t.root + "/elsewhere.jpg")
    let (summary, events) = try t.run()
    #expect(summary.skipped == 2 && summary.created == 0)
    #expect(Set(events) == [.skipRealFile("a.jpg"), .skipPointsElsewhere("b.jpg")])
    #expect(t.links(in: "flat")["b.jpg"] == t.root + "/elsewhere.jpg")
}

@Test func extensionFilter() throws {
    let t = try Tree()
    try t.touch("src/a.CR3", "src/b.jpg", "src/c.png")
    let (summary, _) = try t.run { $0.extensions = ["cr3"] }
    #expect(summary.created == 1 && Array(t.links(in: "flat").keys) == ["a.CR3"])
}

@Test func skipPairedJPEGsOnlyWithinTheSameFolder() throws {
    let t = try Tree()
    try t.touch(
        "src/GR3/R0001.DNG", "src/GR3/R0001.JPG", "src/GR3/R0002.JPG",
        "src/X100VI/DSCF1.RAF", "src/X100VI/dscf1.jpeg",   // pairing ignores case
        "src/split/raw/A.DNG", "src/split/jpg/A.JPG"       // different folders: both kept
    )
    let (summary, _) = try t.run { $0.skipPairedJPEGs = true }
    #expect(summary.paired == 2 && summary.created == 5)
    #expect(Set(t.links(in: "flat").keys) == [
        "GR3__R0001.DNG", "GR3__R0002.JPG", "X100VI__DSCF1.RAF", "split__raw__A.DNG", "split__jpg__A.JPG",
    ])
}

@Test func pairedJPEGsAreDecidedByWhatIsOnDiskNotByTheExtensionFilter() throws {
    let t = try Tree()
    try t.touch("src/A.DNG", "src/A.JPG", "src/B.JPG")
    let (summary, _) = try t.run { $0.skipPairedJPEGs = true; $0.extensions = ["jpg"] }
    #expect(summary.paired == 1 && Array(t.links(in: "flat").keys) == ["B.JPG"])
}

@Test func withoutTheFlagPairsAreBothLinked() throws {
    let t = try Tree()
    try t.touch("src/A.DNG", "src/A.JPG")
    let (summary, _) = try t.run()
    #expect(summary.created == 2 && summary.paired == 0)
}

@Test func rejectsAMissingSourceAndDestEqualToSource() throws {
    let t = try Tree()
    #expect(throws: FlattenError.sourceNotFolder(t.root + "/nope")) { try t.run("nope") }
    try t.touch("src/a.jpg")
    #expect(throws: FlattenError.destIsSource) { try t.run("src", "src") }
}

@Test func canonicalPathResolvesExistingPrefixAndKeepsTheMissingTail() {
    #expect(canonicalPath("/tmp") == "/private/tmp")
    #expect(canonicalPath("/tmp/does-not-exist/x") == "/private/tmp/does-not-exist/x")
    #expect(canonicalPath("/") == "/")
}

@Test func splitExtensionIsLowercasedAndNeedsADot() {
    #expect(splitExtension("IMG_1.CR3")! == ("img_1", "cr3"))
    #expect(splitExtension("a.b.JPG")! == ("a.b", "jpg"))
    #expect(splitExtension("noext") == nil)
    #expect(splitExtension(".hidden") == nil)
}
