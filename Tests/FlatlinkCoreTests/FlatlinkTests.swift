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
    #expect(t.links(in: "flat") == ["b.jpg": t.root + "/elsewhere.jpg"])
    #expect(try t.fm.attributesOfItem(atPath: t.root + "/flat/a.jpg")[.type] as? FileAttributeType == .typeRegular)
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

@Test func pruneRemovesLinksToJPEGsNowLeftOutBesideTheirRAW() throws {
    // Linked before the flag was on: each shot is in the link folder twice until pruning takes the JPEG out.
    let t = try Tree()
    try t.touch("src/day/A.DNG", "src/day/A.JPG", "src/day/B.JPG", "src/other.jpg")
    _ = try t.run()
    try t.touch("flat/day__A.JPG.dop")

    let (kept, keptEvents) = try t.run { $0.skipPairedJPEGs = true }
    #expect(kept.pruned == 0 && kept.paired == 1 && keptEvents.isEmpty)
    #expect(t.links(in: "flat")["day__A.JPG"] != nil)

    let (summary, events) = try t.run { $0.skipPairedJPEGs = true; $0.prune = true }
    #expect(summary.pruned == 1 && summary.kept == 3 && events == [.prune("day__A.JPG")])
    #expect(Set(t.links(in: "flat").keys) == ["day__A.DNG", "day__B.JPG", "other.jpg"])
    #expect(t.fm.fileExists(atPath: t.root + "/src/day/A.JPG"))
    #expect(t.fm.fileExists(atPath: t.root + "/flat/day__A.JPG.dop"))
}

@Test func pruneLeavesJPEGLinksAloneWithoutTheFlag() throws {
    let t = try Tree()
    try t.touch("src/A.DNG", "src/A.JPG")
    _ = try t.run()
    let (summary, _) = try t.run { $0.prune = true }
    #expect(summary.pruned == 0 && summary.kept == 2)
}

@Test func pruneLeavesALinkToAPairedJPEGInAnotherSourceAlone() throws {
    let t = try Tree()
    try t.touch("src/b.jpg", "other/A.DNG", "other/A.JPG")
    try t.fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/A.JPG", withDestinationPath: t.root + "/other/A.JPG")
    let (summary, _) = try t.run { $0.skipPairedJPEGs = true; $0.prune = true }
    #expect(summary.pruned == 0 && summary.created == 1)
    #expect(t.links(in: "flat")["A.JPG"] == t.root + "/other/A.JPG")
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

// MARK: - Re-running after the source moved

@Test func rerunRepointsLinksLeftDanglingByAMovedSource() throws {
    let t = try Tree()
    try t.touch("old/day/A.RAF", "old/top.jpg")
    _ = try t.run("old", "flat")
    try t.fm.moveItem(atPath: t.root + "/old", toPath: t.root + "/new")   // or the drive mounts elsewhere
    try t.touch("flat/day__A.RAF.dop")

    let (dry, dryEvents) = try t.run("new", "flat") { $0.dryRun = true }
    #expect(dry.relinked == 2 && dryEvents == [.relink("day__A.RAF"), .relink("top.jpg")])
    #expect(t.links(in: "flat")["day__A.RAF"] == t.root + "/old/day/A.RAF")

    let (summary, events) = try t.run("new", "flat") { $0.prune = true }
    #expect(summary.relinked == 2 && summary.created == 0 && summary.skipped == 0 && summary.pruned == 0)
    #expect(events == dryEvents)
    #expect(t.links(in: "flat") == [
        "day__A.RAF": t.root + "/new/day/A.RAF",
        "top.jpg": t.root + "/new/top.jpg",
    ])
    // Nothing but the two links and the sidecar: no temporary name is left behind.
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == ["day__A.RAF", "day__A.RAF.dop", "top.jpg"])

    let (again, _) = try t.run("new", "flat")
    #expect(again.kept == 2 && again.relinked == 0)
}

@Test func rerunRepointsADanglingLinkIntoTheSourceWhateverItPointedAt() throws {
    // Two images share a link name and the one that held the link is deleted: the other takes it over.
    let t = try Tree()
    try t.touch("src/a/b__c.jpg", "src/a__b/c.jpg")
    _ = try t.run()
    #expect(t.links(in: "flat") == ["a__b__c.jpg": t.root + "/src/a/b__c.jpg"])
    try t.fm.removeItem(atPath: t.root + "/src/a/b__c.jpg")
    // With --prune too: a link that is repointed is not one to remove.
    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.relinked == 1 && summary.pruned == 0 && events == [.relink("a__b__c.jpg")])
    #expect(t.links(in: "flat") == ["a__b__c.jpg": t.root + "/src/a__b/c.jpg"])
}

@Test func aLinkThatWorksIsNeverRepointed() throws {
    // Two sources hold a photo of the same name, and a link into the source leads to another photo.
    let t = try Tree()
    try t.touch("volA/IMG_0001.CR3", "volA/day/x.jpg", "volA/other.jpg", "volB/IMG_0001.CR3")
    _ = try t.run("volB", "flat")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/day__x.jpg", withDestinationPath: t.root + "/volA/other.jpg")
    let before = t.links(in: "flat")

    for dryRun in [true, false] {
        let (summary, events) = try t.run("volA", "flat") { $0.prune = true; $0.dryRun = dryRun }
        #expect(summary.skipped == 2 && summary.relinked == 0 && summary.created == 1)
        #expect(events == [.skipPointsElsewhere("IMG_0001.CR3"), .skipPointsElsewhere("day__x.jpg"), .link("other.jpg")])
    }
    #expect(t.links(in: "flat").filter { $0.key != "other.jpg" } == before)
}

@Test func aLinkThatLeadsToTheOriginalIsKeptHoweverItIsSpelled() throws {
    let t = try Tree()
    try t.touch("src/cam/c.RAF")
    try t.fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/cam__c.RAF", withDestinationPath: "../src/cam/c.RAF")
    let (summary, events) = try t.run()
    #expect(summary.kept == 1 && events.isEmpty)
    #expect(t.links(in: "flat") == ["cam__c.RAF": "../src/cam/c.RAF"])
}

@Test func aDanglingLinkThatIsNotOursIsNeverRepointed() throws {
    let t = try Tree()
    try t.touch("src/day/a.jpg")
    try t.fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/day__a.jpg", withDestinationPath: t.root + "/unplugged/other.jpg")
    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.skipped == 1 && summary.relinked == 0 && summary.pruned == 0)
    #expect(events == [.skipPointsElsewhere("day__a.jpg")])
    #expect(t.links(in: "flat") == ["day__a.jpg": t.root + "/unplugged/other.jpg"])
}

// MARK: - Prune safety

@Test func pruneInADryRunOrFromTheWrongSourceRemovesNothing() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/gone.jpg", "other/live.jpg", "flat/sub/inner.jpg", "flat/notes.txt")
    _ = try t.run()
    try t.touch("flat/a.jpg.dop", "flat/gone.jpg.dop")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/foreign-live.jpg", withDestinationPath: t.root + "/other/live.jpg")
    try t.fm.removeItem(atPath: t.root + "/src/gone.jpg")
    let before = try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted()

    // 1. dry run + prune reports but removes nothing
    let (dry, dryEvents) = try t.run { $0.prune = true; $0.dryRun = true }
    #expect(dry.pruned == 1 && dryEvents == [.prune("gone.jpg")])
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before)

    // 2. missing source: throws, nothing removed
    #expect(throws: FlattenError.sourceNotFolder(t.root + "/missing")) { try t.run("missing") { $0.prune = true } }
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before)

    // 3. another source: the dangling link points into src, so it is not this run's to remove
    try t.fm.createDirectory(atPath: t.root + "/empty", withIntermediateDirectories: true)
    let (wrong, wrongEvents) = try t.run("empty") { $0.prune = true }
    #expect(wrong.pruned == 0 && wrongEvents.isEmpty)
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before)

    // 4. the right source: only the dangling link goes; live links (ours and foreign), folders, files, .dop stay
    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.pruned == 1 && events == [.prune("gone.jpg")])
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before.filter { $0 != "gone.jpg" })
    #expect(t.links(in: "flat") == [
        "a.jpg": t.root + "/src/a.jpg",
        "foreign-live.jpg": t.root + "/other/live.jpg",
    ])
    #expect(t.fm.fileExists(atPath: t.root + "/flat/sub/inner.jpg"))
}

@Test func pruneLeavesLinksIntoOtherFoldersAlone() throws {
    // Two sources feed one link folder, and one of them is unplugged; the user also keeps a link of their own.
    let t = try Tree()
    try t.touch("volA/Photos/a.jpg", "volA/Photos/deleted.jpg", "volB/Pics/trip/z.NEF")
    _ = try t.run("volA/Photos", "flat")
    _ = try t.run("volB/Pics", "flat")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/mine.jpg", withDestinationPath: "/Volumes/NotMounted/mine.jpg")
    try t.fm.moveItem(atPath: t.root + "/volB", toPath: t.root + "/volB.unplugged")
    try t.fm.removeItem(atPath: t.root + "/volA/Photos/deleted.jpg")

    let (summary, events) = try t.run("volA/Photos", "flat") { $0.prune = true }
    #expect(summary.pruned == 1 && summary.kept == 1 && events == [.prune("deleted.jpg")])
    #expect(t.links(in: "flat") == [
        "a.jpg": t.root + "/volA/Photos/a.jpg",
        "trip__z.NEF": t.root + "/volB/Pics/trip/z.NEF",
        "mine.jpg": "/Volumes/NotMounted/mine.jpg",
    ])
}

@Test func pruneDoesNotMistakeASimilarlyNamedFolderForTheSource() throws {
    let t = try Tree()
    try t.touch("photos/a.jpg", "photos-old/b.jpg")
    _ = try t.run("photos", "flat")
    _ = try t.run("photos-old", "flat")
    try t.fm.removeItem(atPath: t.root + "/photos-old")
    let (summary, events) = try t.run("photos", "flat") { $0.prune = true }
    #expect(summary.pruned == 0 && events.isEmpty)
    #expect(t.links(in: "flat")["b.jpg"] == t.root + "/photos-old/b.jpg")
}

@Test func pruneKeepsLinksWhoseOriginalCannotBeReached() throws {
    let t = try Tree()
    try t.touch("src/open/a.jpg", "src/locked/b.jpg")
    _ = try t.run()
    let locked = t.root + "/src/locked"
    try t.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? t.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.pruned == 0 && summary.kept == 1 && summary.failed == 1)
    #expect(events.count == 1 && events.contains { if case .unreadable(locked, _) = $0 { true } else { false } })
    #expect(Set(t.links(in: "flat").keys) == ["open__a.jpg", "locked__b.jpg"])
}

@Test func pruneRefusesWhenTheSourceHasNoImages() throws {
    // An unplugged drive can leave its mount point behind as an empty folder.
    let t = try Tree()
    try t.touch("vol/Photos/2026/a.CR3", "vol/Photos/b.jpg")
    _ = try t.run("vol/Photos", "flat")
    try t.touch("flat/b.jpg.dop")
    try t.fm.moveItem(atPath: t.root + "/vol", toPath: t.root + "/vol.unplugged")
    try t.fm.createDirectory(atPath: t.root + "/vol/Photos", withIntermediateDirectories: true)
    let before = try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted()

    for dryRun in [true, false] {
        #expect(throws: FlattenError.pruneFoundNoImages(t.root + "/vol/Photos")) {
            try t.run("vol/Photos", "flat") { $0.prune = true; $0.dryRun = dryRun }
        }
        #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before)
    }
    // Without --prune an empty source is not an error, and changes nothing.
    let (summary, events) = try t.run("vol/Photos", "flat")
    #expect(summary == FlattenSummary(dest: t.root + "/flat") && events.isEmpty)
}

/// Runs hdiutil, which makes and mounts the disk images that stand in for drives here.
func hdiutil(_ arguments: String...) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test func aSourceOnAnotherDriveMountedInItsPlaceIsRefused() throws {
    // Two drives of the same name mount at the same place, one at a time.
    let t = try Tree()
    let mount = t.root + "/Volumes/Photos"
    try t.fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
    for drive in ["mine", "other"] {
        #expect(try hdiutil("create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "Photos", t.root + "/\(drive).dmg") == 0)
    }
    func attach(_ drive: String) throws {
        try #require(try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount, t.root + "/\(drive).dmg") == 0)
    }
    func detach() { _ = try? hdiutil("detach", "-quiet", "-force", mount) }
    defer { detach(); withExtendedLifetime(t) {} }

    try attach("mine")
    try t.touch("Volumes/Photos/2026/a.jpg", "Volumes/Photos/b.jpg")
    let mine = try #require(volumeIdentity(of: mount))
    #expect(volumeIdentity(of: t.root) == nil) // the startup drive, which nothing can take the place of
    func run(on drive: String? = mine, dryRun: Bool = false) throws -> (FlattenSummary, [FlattenEvent]) {
        try t.run("Volumes/Photos", "flat") { $0.sourceVolume = drive; $0.prune = true; $0.dryRun = dryRun }
    }
    #expect(try run().0.created == 2)
    let links = t.links(in: "flat")
    detach()

    // The other drive holds a photo, so it doesn't look like an empty mount point. Taken for the
    // source's drive, it would lose every link into the drive that isn't there.
    try attach("other")
    try t.touch("Volumes/Photos/c.jpg")
    #expect(try run(on: nil, dryRun: true).0.pruned == 2)
    for dryRun in [true, false] {
        #expect(throws: FlattenError.sourceOnOtherDrive(mount)) { try run(dryRun: dryRun) }
    }
    detach()
    // Nor is the mount point left behind, a folder on the startup drive.
    #expect(throws: FlattenError.sourceOnOtherDrive(mount)) { try run() }
    #expect(t.links(in: "flat") == links)

    try attach("mine")
    let (summary, events) = try run()
    #expect(summary.kept == 2 && summary.pruned == 0 && events.isEmpty)
}

@Test func pruneRefusesAFolderLeftWhereAnUnpluggedDriveWas() throws {
    // The command can't record the drive, so a folder with photos in it where the drive is mounted,
    // written to while the drive was out, must not pass for the drive.
    let t = try Tree()
    let mount = t.root + "/Volumes/Photos"
    try t.fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
    #expect(try hdiutil("create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "Photos", t.root + "/photos.dmg") == 0)
    func attach() throws {
        try #require(try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount, t.root + "/photos.dmg") == 0)
    }
    func detach() { _ = try? hdiutil("detach", "-quiet", "-force", mount) }
    defer { detach(); withExtendedLifetime(t) {} }
    func run(prune: Bool = true, dryRun: Bool = false) throws -> (FlattenSummary, [FlattenEvent]) {
        try t.run("Volumes/Photos/Library", "flat") {
            $0.volumesFolder = t.root + "/Volumes"; $0.prune = prune; $0.dryRun = dryRun
        }
    }

    try attach()
    try t.touch("Volumes/Photos/Library/2026/a.jpg", "Volumes/Photos/Library/b.jpg")
    #expect(try run().0.created == 2)
    let links = t.links(in: "flat")
    detach()

    try t.touch("Volumes/Photos/Library/stray.jpg")
    #expect(unmountedDrive(holding: t.root + "/Volumes/Photos/Library", volumes: t.root + "/Volumes") == mount)
    for dryRun in [true, false] {
        #expect(throws: FlattenError.pruneDriveNotMounted(mount)) { try run(dryRun: dryRun) }
    }
    #expect(t.links(in: "flat") == links)
    // Without --prune nothing is lost, so the run goes ahead.
    #expect(try run(prune: false).0.created == 1)
    try t.fm.removeItem(atPath: t.root + "/flat/stray.jpg")
    try t.fm.removeItem(atPath: t.root + "/Volumes/Photos/Library")

    try attach()
    #expect(unmountedDrive(holding: t.root + "/Volumes/Photos/Library", volumes: t.root + "/Volumes") == nil)
    let (summary, events) = try run()
    #expect(summary.kept == 2 && summary.pruned == 0 && events.isEmpty)
}

@Test func onlyFoldersBelowTheVolumesFolderCanBeStandIns() throws {
    let t = try Tree()
    try t.touch("Pictures/a.jpg")
    #expect(unmountedDrive(holding: t.root + "/Pictures", volumes: t.root + "/Volumes") == nil)
    #expect(unmountedDrive(holding: "/Users", volumes: "/Volumes") == nil)
}

// MARK: - Names and paths

@Test func imagesWithTheSameLinkNameAreReportedNotDropped() throws {
    let t = try Tree()
    try t.touch("src/a/b/c.jpg", "src/a/b__c.jpg", "src/a__b/c.jpg", "src/a__b__c.jpg", "src/other.jpg")
    let first = t.root + "/src/a/b/c.jpg"
    let expected: [FlattenEvent] = [
        .link("a__b__c.jpg"),
        .collision(name: "a__b__c.jpg", source: t.root + "/src/a/b__c.jpg", holder: first),
        .collision(name: "a__b__c.jpg", source: t.root + "/src/a__b/c.jpg", holder: first),
        .collision(name: "a__b__c.jpg", source: t.root + "/src/a__b__c.jpg", holder: first),
        .link("other.jpg"),
    ]
    let (dry, dryEvents) = try t.run { $0.dryRun = true }
    let (summary, events) = try t.run()
    #expect(events == expected && dryEvents == expected)
    #expect(summary.found == 5 && summary.created == 2 && summary.skipped == 3)
    #expect(dry == summary)
    #expect(t.links(in: "flat") == ["a__b__c.jpg": first, "other.jpg": t.root + "/src/other.jpg"])
}

@Test func theImageALinkAlreadyLeadsToKeepsItWhenARivalAppears() throws {
    // The link, and the edits saved beside it, must not pass to an image that merely sorts first.
    let t = try Tree()
    try t.touch("src/a__b/c.jpg")
    _ = try t.run()
    try t.touch("src/a/b__c.jpg", "flat/a__b__c.jpg.dop")
    let (summary, events) = try t.run()
    #expect(summary.kept == 1 && summary.skipped == 1 && summary.created == 0)
    #expect(events == [.collision(name: "a__b__c.jpg", source: t.root + "/src/a/b__c.jpg", holder: t.root + "/src/a__b/c.jpg")])
    #expect(t.links(in: "flat") == ["a__b__c.jpg": t.root + "/src/a__b/c.jpg"])
}

@Test func namesThatDifferOnlyInCaseCollideWhereTheLinkFolderIgnoresCase() throws {
    let t = try Tree()
    try t.touch("src/x/img.jpg", "src/x__IMG.JPG")
    let (summary, events) = try t.run()
    if Volume(of: t.root).caseSensitive {
        #expect(summary.created == 2 && events == [.link("x__IMG.JPG"), .link("x__img.jpg")])
    } else {
        #expect(summary.created == 1 && summary.skipped == 1)
        #expect(events == [
            .link("x__img.jpg"),
            .collision(name: "x__IMG.JPG", source: t.root + "/src/x__IMG.JPG", holder: t.root + "/src/x/img.jpg"),
        ])
        let (again, _) = try t.run { $0.prune = true }
        #expect(again.kept == 1 && again.skipped == 1 && again.pruned == 0)
    }
}

/// A path deep enough that the joined link name exceeds NAME_MAX (255 bytes).
@Test func linkNameLongerThan255BytesIsReportedAsFailedNotDropped() throws {
    let t = try Tree()
    let folder = String(repeating: "x", count: 100)
    try t.touch("src/\(folder)/\(folder)/\(folder)/IMG_0001.CR3", "src/ok.jpg")
    let name = [folder, folder, folder, "IMG_0001.CR3"].joined(separator: linkSeparator)
    #expect(name.utf8.count > 255)

    let (dry, dryEvents) = try t.run { $0.dryRun = true }
    let (summary, events) = try t.run()
    #expect(summary.created == 1 && summary.failed == 1, "summary: \(summary)")
    #expect(events.contains(.link("ok.jpg")))
    #expect(events.contains { if case .failed(name, _) = $0 { true } else { false } })
    #expect(Array(t.links(in: "flat").keys) == ["ok.jpg"])
    #expect(dry == summary && dryEvents == events)
}

/// APFS holds a name to 255 UTF-16 units, not 255 bytes. Decomposed, as Foundation writes it, each
/// accented letter is two units but three bytes, so counting bytes refused names that fit.
@Test func accentedLinkNamesAreMeasuredAsTheyAreStored() throws {
    let t = try Tree()
    #expect(Volume(of: t.root).countsUTF16)
    let accents = String(repeating: "é", count: 60)
    try t.touch("src/\(accents)/\(accents).jpg")
    let stored = "\(accents)__\(accents).jpg".decomposedStringWithCanonicalMapping
    #expect(stored.utf16.count == 246 && stored.utf8.count == 366)

    let (summary, events) = try t.run()
    #expect(summary.created == 1 && summary.failed == 0, "events: \(events)")
    #expect(t.links(in: "flat").count == 1)

    // One that is too long as stored still fails: 200 + 2 + 54 + 4 = 260 units.
    try t.touch("src/\(String(repeating: "é", count: 100))/\(String(repeating: "é", count: 27)).jpg")
    let (again, _) = try t.run()
    #expect(again.kept == 1 && again.failed == 1)
}

@Test func nameLengthCountsDecomposedUnitsOrBytes() throws {
    var volume = Volume(of: try Tree().root)
    volume.countsUTF16 = true
    #expect(volume.length(of: "é") == 2 && volume.length(of: "e\u{301}") == 2)
    #expect(volume.length(of: "😀") == 2 && volume.length(of: "写") == 1)
    volume.countsUTF16 = false
    #expect(volume.length(of: "é") == 3 && volume.length(of: "写") == 3)
    #expect(volume.length(of: "IMG_0001.CR3") == 12)
}

/// Destination (and source) addressed through a symlinked path; destination inside the source
/// holding a real image (for example a PhotoLab export written beside the links).
@Test func symlinkedPathsAndRealImagesInADestInsideTheSource() throws {
    let t = try Tree()
    try t.touch("src/a/one.jpg", "src/_flat/one_DxO.jpg", "realflat/keep.txt")
    try t.fm.createSymbolicLink(atPath: t.root + "/flatalias", withDestinationPath: t.root + "/realflat")
    try t.fm.createSymbolicLink(atPath: t.root + "/srcalias", withDestinationPath: t.root + "/src")

    // dest through a symlink: links land in the real folder, the alias stays a symlink
    let (first, _) = try t.run("src", "flatalias")
    #expect(first.dest == t.root + "/realflat")
    #expect(try t.fm.destinationOfSymbolicLink(atPath: t.root + "/flatalias") == t.root + "/realflat")
    #expect(t.links(in: "realflat")["a__one.jpg"] == t.root + "/src/a/one.jpg")

    // same tree through aliases on both sides: recognised as the same links
    let (second, events) = try t.run("srcalias", "flatalias")
    #expect(second.created == 0 && second.skipped == 0, "summary: \(second), events: \(events)")

    // source == dest through an alias is still rejected
    #expect(throws: FlattenError.destIsSource) { try t.run("srcalias", "src") }

    // dest inside the source, reached through the alias: its real image must not be linked
    let (inside, _) = try t.run("srcalias", "srcalias/_flat")
    #expect(inside.created == 1)
    #expect(t.links(in: "src/_flat") == ["a__one.jpg": t.root + "/src/a/one.jpg"])
}

// MARK: - Incomplete results

@Test func foldersThatCannotBeReadAreReported() throws {
    let t = try Tree()
    try t.touch("src/open/a.jpg", "src/locked/b.jpg")
    let locked = t.root + "/src/locked"
    try t.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? t.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

    let (summary, events) = try t.run()
    #expect(summary.found == 1 && summary.created == 1 && summary.failed == 1)
    #expect(events.count == 2 && events.last == .link("open__a.jpg"))
    #expect(events.contains { if case .unreadable(locked, _) = $0 { true } else { false } })
}

@Test func aSourceThatCannotBeReadIsReported() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    _ = try t.run()
    let source = t.root + "/src"
    try t.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source)
    defer { try? t.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source) }

    let (summary, events) = try t.run { $0.prune = true }
    #expect(summary.found == 0 && summary.failed == 1 && summary.pruned == 0)
    #expect(events.count == 1 && events.contains { if case .unreadable(source, _) = $0 { true } else { false } })
    #expect(Array(t.links(in: "flat").keys) == ["a.jpg"])
}

@Test func summaryCountsTheImagesFound() throws {
    let t = try Tree()
    try t.touch("src/A.DNG", "src/A.JPG", "src/b.jpg", "src/notes.txt", "flat/b.jpg")
    let (summary, _) = try t.run { $0.skipPairedJPEGs = true }
    #expect(summary.found == 2 && summary.paired == 1 && summary.created == 1 && summary.skipped == 1)
    let (none, events) = try t.run { $0.extensions = ["cr3"] }
    #expect(none.found == 0 && events.isEmpty)
}

// MARK: - A dry run foresees what the real run meets

@Test func dryRunMatchesTheRealRun() throws {
    let t = try Tree()
    try t.touch(
        "src/new.jpg", "src/kept.jpg", "src/gone.jpg", "src/day/moved.CR3", "src/a/b.jpg", "src/a__b.jpg",
        "src/real.jpg", "src/foreign.jpg", "flat/real.jpg", "elsewhere.jpg"
    )
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/kept.jpg", withDestinationPath: t.root + "/src/kept.jpg")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/gone.jpg", withDestinationPath: t.root + "/src/gone.jpg")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/day__moved.CR3", withDestinationPath: t.root + "/before/day/moved.CR3")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/foreign.jpg", withDestinationPath: t.root + "/elsewhere.jpg")
    try t.fm.removeItem(atPath: t.root + "/src/gone.jpg")
    let before = try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted()

    let (dry, dryEvents) = try t.run { $0.dryRun = true; $0.prune = true }
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == before)
    #expect(t.links(in: "flat")["day__moved.CR3"] == t.root + "/before/day/moved.CR3")

    let (summary, events) = try t.run { $0.prune = true }
    #expect(dry == summary && dryEvents == events)
    #expect(summary == FlattenSummary(found: 7, created: 2, kept: 1, relinked: 1, skipped: 3, pruned: 1, dest: t.root + "/flat"))
    #expect(Set(events) == [
        .link("new.jpg"), .link("a__b.jpg"), .relink("day__moved.CR3"), .prune("gone.jpg"),
        .skipRealFile("real.jpg"), .skipPointsElsewhere("foreign.jpg"),
        .collision(name: "a__b.jpg", source: t.root + "/src/a__b.jpg", holder: t.root + "/src/a/b.jpg"),
    ])
}

@Test func aDestThatIsNotAFolderIsRejectedBeforeAnythingIsDone() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "file.jpg", "folder/file")
    try t.fm.createSymbolicLink(atPath: t.root + "/broken", withDestinationPath: t.root + "/nowhere")
    for dryRun in [true, false] {
        #expect(throws: FlattenError.destNotFolder(t.root + "/file.jpg")) { try t.run("src", "file.jpg") { $0.dryRun = dryRun } }
        #expect(throws: FlattenError.destNotFolder(t.root + "/folder/file")) {
            try t.run("src", "folder/file/flat") { $0.dryRun = dryRun }
        }
        #expect(throws: FlattenError.destNotFolder(t.root + "/broken")) { try t.run("src", "broken") { $0.dryRun = dryRun } }
    }
    #expect(try t.fm.destinationOfSymbolicLink(atPath: t.root + "/broken") == t.root + "/nowhere")
}

@Test func aDestThatCannotBeWrittenToIsRejectedUnlessThereIsNothingToWrite() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    _ = try t.run()
    let flat = t.root + "/flat", parent = t.root + "/readonly"
    try t.fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
    try t.fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: flat)
    try t.fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
    defer {
        try? t.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flat)
        try? t.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
    }

    // Every link is in place: a link folder that can only be read is fine.
    let (summary, _) = try t.run()
    #expect(summary.kept == 1 && summary.failed == 0)

    try t.touch("src/b.jpg")
    for dryRun in [true, false] {
        #expect(throws: FlattenError.destNotWritable(flat)) { try t.run { $0.dryRun = dryRun } }
        #expect(throws: FlattenError.destNotWritable(parent + "/flat")) { try t.run("src", "readonly/flat") { $0.dryRun = dryRun } }
    }
    #expect(Array(t.links(in: "flat").keys) == ["a.jpg"])
}

// MARK: - Promises

@Test func theSourceAndEveryFileInTheLinkFolderAreLeftAsTheyWere() throws {
    let t = try Tree()
    let files = [
        "src/a.jpg": "original", "src/day/b.CR3": "raw", "src/day/b.CR3.dop": "edits beside the original",
        "src/gone.jpg": "deleted below", "flat/a.jpg.dop": "edits", "flat/export.jpg": "an export", "flat/day__b.CR3": "in the way",
    ]
    for (path, content) in files {
        try t.touch(path)
        try Data(content.utf8).write(to: URL(fileURLWithPath: t.root + "/" + path))
    }
    func snapshot(_ folder: String) throws -> [String: Data] {
        let paths = try t.fm.subpathsOfDirectory(atPath: t.root + "/" + folder)
        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            let full = t.root + "/" + folder + "/" + path
            guard (try? t.fm.destinationOfSymbolicLink(atPath: full)) == nil else { return nil }
            return (path, t.fm.contents(atPath: full) ?? Data())
        })
    }
    let (source, flat) = (try snapshot("src"), try snapshot("flat"))

    _ = try t.run()
    try t.fm.removeItem(atPath: t.root + "/src/gone.jpg")
    let (summary, _) = try t.run { $0.prune = true }
    #expect(summary.kept == 1 && summary.pruned == 1 && summary.skipped == 1)

    #expect(try snapshot("src") == source.filter { $0.key != "gone.jpg" })
    #expect(try snapshot("flat") == flat)
    #expect(Array(t.links(in: "flat").keys) == ["a.jpg"])
}

@Test func theFormatsLinkedByDefault() throws {
    // README and --help promise "JPEG, TIFF, HEIC, PNG and 24 RAW formats".
    #expect(ImageTypes.raw.count == 24)
    #expect(ImageTypes.all == [
        "jpg", "jpeg", "jpe", "tif", "tiff", "heic", "heif", "png",
        "dng", "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "orf", "raf", "rw2",
        "rwl", "pef", "srw", "3fr", "fff", "iiq", "erf", "mef", "mos", "mrw", "x3f", "gpr",
    ])
    #expect(FlattenOptions(source: "a", dest: "b").extensions == ImageTypes.all)

    let t = try Tree()
    for ext in ImageTypes.all { try t.touch("src/IMG." + ext.uppercased()) }
    try t.touch("src/IMG.dop", "src/IMG.txt", "src/IMG.xmp", "src/IMG.mov")
    let (summary, _) = try t.run()
    #expect(summary.found == 32 && summary.created == 32)
}

@Test func eventsComeInTheOrderOfTheSourcePaths() throws {
    let t = try Tree()
    try t.touch("src/b/1.jpg", "src/a/2.jpg", "src/c.jpg", "src/a/1.jpg", "src/B.jpg")
    let (_, events) = try t.run()
    #expect(events == [.link("B.jpg"), .link("a__1.jpg"), .link("a__2.jpg"), .link("b__1.jpg"), .link("c.jpg")])

    for name in ["c.jpg", "a/1.jpg", "b/1.jpg"] { try t.fm.removeItem(atPath: t.root + "/src/" + name) }
    let (_, pruned) = try t.run { $0.prune = true }
    #expect(pruned == [.prune("a__1.jpg"), .prune("b__1.jpg"), .prune("c.jpg")])
}

@Test func skipsPhotoLibrariesAndFoldersReachedThroughALink() throws {
    let t = try Tree()
    try t.touch("src/Photos Library.photoslibrary/originals/0/IMG.HEIC", "src/ok.jpg", "outside/album/far.jpg")
    try t.fm.createSymbolicLink(atPath: t.root + "/src/album", withDestinationPath: t.root + "/outside/album")
    let (summary, _) = try t.run()
    #expect(summary.found == 1 && Array(t.links(in: "flat").keys) == ["ok.jpg"])
}

@Test func anEmptyPathIsNeverTheCurrentFolder() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    #expect(throws: FlattenError.sourceNotFolder("")) { try flatten(FlattenOptions(source: "", dest: t.root + "/flat")) }
    #expect(throws: FlattenError.destNotFolder("")) { try flatten(FlattenOptions(source: t.root + "/src", dest: "")) }
}

@Test func canonicalPathTakesRelativePathsFromTheGivenFolder() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    #expect(canonicalPath("src", relativeTo: t.root) == t.root + "/src")
    #expect(canonicalPath("./src/../src/", relativeTo: t.root) == t.root + "/src")
    #expect(canonicalPath("new/folder", relativeTo: t.root) == t.root + "/new/folder")
    #expect(canonicalPath("/tmp", relativeTo: t.root) == "/private/tmp")
    #expect(canonicalPath(".") == canonicalPath(t.fm.currentDirectoryPath))
}

// MARK: - When a change fails after all

@Test func changesThatFailAreReportedAndCounted() throws {
    // The plan is made from what is there; by the time it is carried out, something may have changed.
    let t = try Tree()
    try t.touch("src/a.jpg", "src/b.jpg", "flat/taken.jpg")
    let plan = FlattenPlan(dest: t.root + "/flat", found: 3, steps: [
        .link("a.jpg", to: t.root + "/src/a.jpg"),
        .link("taken.jpg", to: t.root + "/src/b.jpg"),       // a file has appeared under the name
        .relink("missing/b.jpg", to: t.root + "/src/b.jpg", from: t.root + "/old/b.jpg"), // the folder is not there
        .prune("vanished.jpg", from: t.root + "/src/vanished.jpg"),                       // the link has gone already
    ])
    var events: [FlattenEvent] = []
    let summary = try carryOut(plan, dryRun: false) { events.append($0) }

    #expect(summary == FlattenSummary(found: 3, created: 1, failed: 3, dest: t.root + "/flat"))
    #expect(events.count == 4 && events[0] == .link("a.jpg"))
    for (event, name) in zip(events.dropFirst(), ["taken.jpg", "missing/b.jpg", "vanished.jpg"]) {
        guard case .failed(name, let reason) = event else {
            Issue.record("expected a failure for \(name), got \(event)")
            continue
        }
        #expect(!reason.isEmpty)
    }
    // Nothing was replaced, and no temporary name is left behind.
    #expect(try t.fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == ["a.jpg", "taken.jpg"])
    #expect(t.links(in: "flat") == ["a.jpg": t.root + "/src/a.jpg"])
}

@Test func pruneNeverRemovesAFolder() throws {
    let t = try Tree()
    try t.touch("flat/folder/keep.jpg")
    var events: [FlattenEvent] = []
    let summary = try carryOut(FlattenPlan(dest: t.root + "/flat", steps: [.prune("folder", from: t.root + "/folder")]), dryRun: false) { events.append($0) }
    #expect(summary.pruned == 0 && summary.failed == 1)
    #expect(t.fm.fileExists(atPath: t.root + "/flat/folder/keep.jpg"))
}

// MARK: - Planning first, for an app

@Test func aPlanNeverReplacesOrRemovesWhatWasPutInPlaceOfItsLinksSince() throws {
    // A preview in the app can be carried out long after it was made.
    let t = try Tree()
    try t.touch("src/day/moved.jpg")
    let fm = t.fm
    try fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    for name in ["day__moved.jpg", "gone.jpg", "repointed.jpg"] {
        try fm.createSymbolicLink(atPath: t.root + "/flat/" + name, withDestinationPath: t.root + "/src/" + name)
    }
    var options = FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")
    options.prune = true
    let made = try plan(options)
    var shown: [FlattenEvent] = []
    _ = try carryOut(made, dryRun: true) { shown.append($0) }
    #expect(shown == [.relink("day__moved.jpg"), .prune("gone.jpg"), .prune("repointed.jpg")])

    // Since the preview: real files took the places of two links, and one link was pointed elsewhere.
    for name in ["day__moved.jpg", "gone.jpg", "repointed.jpg"] { try fm.removeItem(atPath: t.root + "/flat/" + name) }
    #expect(fm.createFile(atPath: t.root + "/flat/day__moved.jpg", contents: Data("mine".utf8)))
    #expect(fm.createFile(atPath: t.root + "/flat/gone.jpg", contents: Data("mine".utf8)))
    try fm.createSymbolicLink(atPath: t.root + "/flat/repointed.jpg", withDestinationPath: t.root + "/elsewhere.jpg")

    var done: [FlattenEvent] = []
    let summary = try carryOut(made, dryRun: false) { done.append($0) }
    #expect(summary.relinked == 0 && summary.pruned == 0 && summary.failed == 3)
    #expect(done.map { if case .failed(let name, _) = $0 { name } else { "" } } == ["day__moved.jpg", "gone.jpg", "repointed.jpg"])
    #expect(fm.contents(atPath: t.root + "/flat/day__moved.jpg") == Data("mine".utf8))
    #expect(fm.contents(atPath: t.root + "/flat/gone.jpg") == Data("mine".utf8))
    #expect(t.links(in: "flat") == ["repointed.jpg": t.root + "/elsewhere.jpg"])
    #expect(try fm.contentsOfDirectory(atPath: t.root + "/flat").sorted() == ["day__moved.jpg", "gone.jpg", "repointed.jpg"])
}

@Test func aPlanCarriedOutDoesWhatItsDryRunShowed() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/day/b.CR3")
    let options = FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")
    let made = try plan(options)
    #expect(made.found == 2 && made.dest == t.root + "/flat")

    var shown: [FlattenEvent] = [], done: [FlattenEvent] = []
    let dry = try carryOut(made, dryRun: true) { shown.append($0) }
    #expect(!t.fm.fileExists(atPath: t.root + "/flat"))
    let real = try carryOut(made, dryRun: false) { done.append($0) }
    #expect(dry == real && shown == done && done == [.link("a.jpg"), .link("day__b.CR3")])
}

@Test func planningReportsProgressThroughALargeTree() throws {
    let t = try Tree()
    for i in 0..<600 { try t.touch("src/\(i / 100)/\(i).jpg") }
    var reports: [ScanProgress] = []
    let made = try plan(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")) { reports.append($0) }
    #expect(made.found == 600)
    #expect(reports.count == 2)
    #expect(reports.map(\.items) == [256, 512])
    #expect(reports.allSatisfy { $0.folder.hasPrefix(t.root + "/src/") })
}

@Test func planningStopsWhenItsTaskIsCancelled() async throws {
    let t = try Tree()
    for i in 0..<600 { try t.touch("src/\(i).jpg") }
    let options = FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try plan(options)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func carryingOutStopsWhenItsTaskIsCancelled() async throws {
    let t = try Tree()
    for i in 0..<50 { try t.touch("src/\(i).jpg") }
    let made = try plan(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat"))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try carryOut(made, dryRun: false)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(t.links(in: "flat").isEmpty)

    // What a cancelled run leaves is picked up by the next.
    let summary = try carryOut(try plan(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")), dryRun: false)
    #expect(summary.created == 50 && summary.failed == 0)
}

// MARK: - Changing a link without losing what took its place

/// Only what `takeAside` and `replaceLink` leave behind: no hidden names.
private func leftovers(_ t: Tree) -> [String] {
    ((try? t.fm.contentsOfDirectory(atPath: t.root + "/flat")) ?? []).filter { $0.hasPrefix(asidePrefix) }
}

@Test func aLinkIsTakenAsideOnlyWhileItIsStillTheOneThePlanSaw() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/b.jpg")
    try t.fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    let link = t.root + "/flat/a.jpg"
    try t.fm.createSymbolicLink(atPath: link, withDestinationPath: t.root + "/src/a.jpg")

    let aside = try takeAside(link, leadingTo: t.root + "/src/a.jpg")
    #expect(!t.fm.fileExists(atPath: link) && (try? t.fm.destinationOfSymbolicLink(atPath: aside)) == t.root + "/src/a.jpg")
    unlink(aside)

    // A file saved in the link's place since the plan: put back, untouched.
    #expect(t.fm.createFile(atPath: link, contents: Data("export".utf8)))
    #expect(throws: ChangedSincePlanned.self) { try takeAside(link, leadingTo: t.root + "/src/a.jpg") }
    #expect(t.fm.contents(atPath: link) == Data("export".utf8))
    try t.fm.removeItem(atPath: link)

    // Another link: put back too.
    try t.fm.createSymbolicLink(atPath: link, withDestinationPath: t.root + "/src/b.jpg")
    #expect(throws: ChangedSincePlanned.self) { try takeAside(link, leadingTo: t.root + "/src/a.jpg") }
    #expect((try? t.fm.destinationOfSymbolicLink(atPath: link)) == t.root + "/src/b.jpg")
    try t.fm.removeItem(atPath: link)

    // Nothing there any more.
    #expect(throws: ChangedSincePlanned.self) { try takeAside(link, leadingTo: t.root + "/src/a.jpg") }
    #expect(leftovers(t).isEmpty)
}

@Test func whatWasTakenAsideStaysAsideWhenItsNameIsTakenAgain() throws {
    let t = try Tree()
    try t.touch("flat/aside.txt", "flat/a.jpg")
    #expect(throws: LeftAside.self) { try putBack(t.root + "/flat/aside.txt", at: t.root + "/flat/a.jpg") }
    #expect(t.fm.fileExists(atPath: t.root + "/flat/aside.txt") && t.fm.fileExists(atPath: t.root + "/flat/a.jpg"))
}

@Test func relinkingKeepsTheNameAndReplacesOnlyTheLinkThePlanSaw() throws {
    let t = try Tree()
    try t.touch("src/new.jpg")
    try t.fm.createDirectory(atPath: t.root + "/flat", withIntermediateDirectories: true)
    let link = t.root + "/flat/a.jpg"
    try t.fm.createSymbolicLink(atPath: link, withDestinationPath: t.root + "/old/a.jpg")

    try replaceLink(at: link, leadingTo: t.root + "/old/a.jpg", with: t.root + "/src/new.jpg")
    #expect(t.links(in: "flat") == ["a.jpg": t.root + "/src/new.jpg"])

    // A file saved in its place since: kept, and nothing half-made is left behind.
    try t.fm.removeItem(atPath: link)
    #expect(t.fm.createFile(atPath: link, contents: Data("export".utf8)))
    #expect(throws: ChangedSincePlanned.self) {
        try replaceLink(at: link, leadingTo: t.root + "/old/a.jpg", with: t.root + "/src/new.jpg")
    }
    #expect(t.fm.contents(atPath: link) == Data("export".utf8))
    #expect(leftovers(t).isEmpty)
}

@Test func aRunRemovesTheLinksAStoppedRunLeftButNothingElse() throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "flat/\(asidePrefix)kept.txt")
    try t.fm.createSymbolicLink(atPath: t.root + "/flat/\(asidePrefix)stale", withDestinationPath: t.root + "/src/a.jpg")

    // A dry run changes nothing, not even this.
    _ = try t.run { $0.dryRun = true }
    #expect(leftovers(t).count == 2)

    let (summary, events) = try t.run()
    #expect(summary.created == 1 && events == [.link("a.jpg")])
    #expect(leftovers(t) == ["\(asidePrefix)kept.txt"])
}

// MARK: - Paths and names

@Test func theStartupDriveIsNotAPhotoFolder() throws {
    let t = try Tree()
    #expect(throws: FlattenError.sourceIsStartupDrive) { try plan(FlattenOptions(source: "/", dest: t.root + "/flat")) }
    #expect(!t.fm.fileExists(atPath: t.root + "/flat"))
}

@Test func pathsBelowTheirRoot() {
    #expect(relativePath("/Volumes/Photos/2026/a.jpg", below: "/Volumes/Photos") == "2026/a.jpg")
    #expect(relativePath("/Users/a.jpg", below: "/") == "Users/a.jpg")
}

@Test func accentsWrittenTwoWaysAreNotTheSameBytes() {
    // Swift's == takes them for one string; a network drive can hold one file named each way.
    #expect("é.jpg" == "e\u{301}.jpg")
    #expect(!sameBytes("é.jpg", "e\u{301}.jpg"))
    #expect(sameBytes("é.jpg", "é.jpg"))
}
