import FlatlinkCore
import Foundation
import Testing
@testable import FlatlinkCommand

/// A throwaway folder the tool is run in, removed when the test ends.
final class Sandbox {
    let root: String
    let fm = FileManager.default

    init() throws {
        root = canonicalPath(NSTemporaryDirectory() + "flatlink-" + UUID().uuidString)
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

    func links(in folder: String) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root + "/" + folder)) ?? []
        return names.filter { (try? fm.destinationOfSymbolicLink(atPath: root + "/" + folder + "/" + $0)) != nil }.sorted()
    }

    /// Runs the tool in the sandbox; paths in `arguments` are relative to it.
    func flatlink(_ arguments: String...) -> (status: Int32, out: [String], err: [String]) {
        var out: [String] = [], err: [String] = []
        let status = run(arguments, version: "9.9.9", directory: root, out: { out.append($0) }, err: { err.append($0) })
        return (status, out, err)
    }
}

// MARK: - Reading the command line

@Test func parsesOptionsInAnyPosition() throws {
    var expected = FlattenOptions(source: "/photos", dest: "/flat")
    #expect(try parse(["/photos", "/flat"], directory: "/") == .flatten(expected, extensions: []))

    expected.dryRun = true
    expected.prune = true
    expected.skipPairedJPEGs = true
    #expect(try parse(["-n", "/photos", "--prune", "/flat", "--skip-paired-jpegs"], directory: "/") == .flatten(expected, extensions: []))
    #expect(try parse(["--dry-run", "--prune", "--skip-paired-jpegs", "/photos", "/flat"], directory: "/") == .flatten(expected, extensions: []))
}

@Test func helpAndVersionWinOverEverythingAfterThem() throws {
    #expect(try parse(["-h"], directory: "/") == .help)
    #expect(try parse(["--help", "a", "b", "c"], directory: "/") == .help)
    #expect(try parse(["--version"], directory: "/") == .version)
    #expect(throws: UsageError(message: "unknown option --bogus")) { try parse(["--bogus", "--help"], directory: "/") }
}

@Test func relativePathsAreTakenFromTheDirectory() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg")
    let expected = FlattenOptions(source: box.root + "/photos", dest: box.root + "/not/yet/there")
    #expect(try parse(["photos", "not/yet/there"], directory: box.root) == .flatten(expected, extensions: []))
    #expect(try parse(["./photos/", "photos/../not/yet/there"], directory: box.root) == .flatten(expected, extensions: []))
    #expect(try parse([box.root + "/photos", "not/yet/there"], directory: "/somewhere/else") != .flatten(expected, extensions: []))
}

@Test func afterTwoDashesEverythingIsAPath() throws {
    let expected = FlattenOptions(source: "/-photos", dest: "/--prune")
    #expect(try parse(["--", "-photos", "--prune"], directory: "/") == .flatten(expected, extensions: []))
    #expect(throws: UsageError(message: "unknown option -photos")) { try parse(["-photos", "flat"], directory: "/") }
}

@Test func extensionsAreLowercasedAndMayComeAsAList() throws {
    var expected = FlattenOptions(source: "/photos", dest: "/flat")
    expected.extensions = ["cr3", "jpg"]
    let spellings: [[String]] = [
        ["--ext", "cr3", "--ext", "jpg"], ["--ext", ".CR3", "--ext=JPG"], ["--ext", "cr3,jpg"], ["--ext=.cr3,.JPG"],
    ]
    for spelling in spellings {
        #expect(try parse(spelling + ["/photos", "/flat"], directory: "/") == .flatten(expected, extensions: ["cr3", "jpg"]))
    }
}

@Test(arguments: ["", ".", "cr3,", ",", "*.cr3", " cr3", "cr3 jpg", "..cr3", "~/Pictures", "photos/2026", "c\u{0301}r3"])
func extensionsThatCannotBeOnesAreRejected(value: String) {
    let error = UsageError(message: "--ext needs an extension such as cr3, got '\(value)'")
    #expect(throws: error) { try parse(["--ext", value, "/photos", "/flat"], directory: "/") }
    #expect(throws: error) { try parse(["--ext=" + value, "/photos", "/flat"], directory: "/") }
}

@Test func extNeedsAValue() {
    let error = UsageError(message: "--ext needs a value, e.g. --ext cr3")
    #expect(throws: error) { try parse(["/photos", "/flat", "--ext"], directory: "/") }
    #expect(throws: error) { try parse(["--ext", "--prune", "/photos", "/flat"], directory: "/") }
}

@Test func needsExactlyTwoPathsAndNeitherEmpty() {
    for (arguments, count) in [([], 0), (["/photos"], 1), (["/photos", "/flat", "/more"], 3), (["-n"], 0)] {
        #expect(throws: UsageError(message: "expected SOURCE and DEST, got \(count) argument(s)")) {
            try parse(arguments, directory: "/")
        }
    }
    // What `flatlink ~/Photos "$UNSET"` turns into.
    let empty = UsageError(message: "SOURCE and DEST can't be empty")
    #expect(throws: empty) { try parse(["/photos", ""], directory: "/") }
    #expect(throws: empty) { try parse(["", "/flat"], directory: "/") }
}

// MARK: - Running

@Test func helpAndVersionGoToStandardOutput() throws {
    let box = try Sandbox()
    let help = box.flatlink("--help")
    #expect(help.status == 0 && help.err.isEmpty && help.out.count == 1)
    #expect(help.out[0].hasPrefix("usage: flatlink "))
    #expect(help.out[0].contains("PNG and 24 RAW formats"))
    for option in ["--dry-run", "--prune", "--skip-paired-jpegs", "--ext EXT", "--help", "--version"] {
        #expect(help.out[0].contains(option))
    }
    let version = box.flatlink("--version")
    #expect(version.status == 0 && version.out == ["flatlink 9.9.9"] && version.err.isEmpty)
}

@Test func usageErrorsExitWith64AndChangeNothing() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg")
    let before = try box.fm.contentsOfDirectory(atPath: box.root)
    let mistakes: [[String]] = [
        [], ["photos"], ["photos", "flat", "more"], ["--bogus", "photos", "flat"], ["photos", "flat", "--ext"],
        ["--ext", "cr3,", "photos", "flat"], ["photos", ""], ["", "flat"], ["missing", "flat"], ["photos", "photos"],
        ["photos/a.jpg", "flat"],
    ]
    for arguments in mistakes {
        var err: [String] = []
        let status = run(arguments, version: "9.9.9", directory: box.root, out: { _ in Issue.record("printed for \(arguments)") }, err: { err.append($0) })
        #expect(status == 64, "\(arguments)")
        #expect(err.count == 1 && err[0].hasPrefix("flatlink: error: ") && err[0].hasSuffix("\nRun 'flatlink --help' for usage."), "\(err)")
    }
    #expect(try box.fm.contentsOfDirectory(atPath: box.root) == before)
}

@Test func aCompleteRunExitsWith0() throws {
    let box = try Sandbox()
    try box.touch("photos/2026/day/A.CR3", "photos/2026/day/A.JPG", "photos/b.jpg", "photos/notes.txt")

    let first = box.flatlink("photos", "flat", "--skip-paired-jpegs")
    #expect(first.status == 0 && first.err.isEmpty)
    #expect(first.out == [
        "link  2026__day__A.CR3", "link  b.jpg",
        "\ncreated 2, kept 0, skipped 0, pruned 0, left out 1 paired JPEGs  ->  \(box.root)/flat",
    ])
    #expect(box.links(in: "flat") == ["2026__day__A.CR3", "b.jpg"])

    let again = box.flatlink("photos", "flat")
    #expect(again.status == 0 && again.err.isEmpty)
    #expect(again.out == ["link  2026__day__A.JPG", "\ncreated 1, kept 2, skipped 0, pruned 0  ->  \(box.root)/flat"])
}

@Test func aDryRunSaysSoAndChangesNothing() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg", "photos/gone.jpg")
    #expect(box.flatlink("photos", "flat").status == 0)
    try box.fm.removeItem(atPath: box.root + "/photos/gone.jpg")
    try box.touch("photos/new.jpg")

    let dry = box.flatlink("-n", "--prune", "photos", "flat")
    #expect(dry.status == 0 && dry.err.isEmpty)
    #expect(dry.out == [
        "link  new.jpg", "prune gone.jpg",
        "\nwould create 1, kept 1, skipped 0, would prune 1  ->  \(box.root)/flat",
        "dry run: nothing was changed",
    ])
    #expect(box.links(in: "flat") == ["a.jpg", "gone.jpg"])

    let real = box.flatlink("--prune", "photos", "flat")
    #expect(real.status == 0)
    #expect(real.out == ["link  new.jpg", "prune gone.jpg", "\ncreated 1, kept 1, skipped 0, pruned 1  ->  \(box.root)/flat"])
    #expect(box.links(in: "flat") == ["a.jpg", "new.jpg"])
}

@Test func aMovedSourceIsRelinked() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg")
    #expect(box.flatlink("photos", "flat").status == 0)
    try box.fm.moveItem(atPath: box.root + "/photos", toPath: box.root + "/pictures")
    let dry = box.flatlink("-n", "pictures", "flat")
    #expect(dry.status == 0 && dry.out.first == "relink a.jpg")
    #expect(dry.out.contains("\nwould create 0, kept 0, skipped 0, would prune 0, would relink 1  ->  \(box.root)/flat"))
    let real = box.flatlink("pictures", "flat")
    #expect(real.status == 0)
    #expect(real.out == ["relink a.jpg", "\ncreated 0, kept 0, skipped 0, pruned 0, relinked 1  ->  \(box.root)/flat"])
}

@Test func imagesLeftOutAreNamedAndExitWith1() throws {
    let box = try Sandbox()
    try box.touch("photos/a/b.jpg", "photos/a__b.jpg", "photos/real.jpg", "photos/ok.jpg", "flat/real.jpg", "other.jpg")
    try box.fm.createSymbolicLink(atPath: box.root + "/flat/ok.jpg", withDestinationPath: box.root + "/other.jpg")

    let result = box.flatlink("photos", "flat")
    #expect(result.status == 1)
    #expect(result.out == ["link  a__b.jpg", "\ncreated 1, kept 0, skipped 3, pruned 0  ->  \(box.root)/flat"])
    #expect(result.err == [
        "skip (link name a__b.jpg belongs to \(box.root)/photos/a/b.jpg): \(box.root)/photos/a__b.jpg",
        "skip (link exists, points elsewhere): ok.jpg",
        "skip (real file in the way): real.jpg",
    ])
}

@Test func foldersThatCannotBeReadAreNamedAndExitWith1() throws {
    let box = try Sandbox()
    try box.touch("photos/open/a.jpg", "photos/locked/b.jpg")
    let locked = box.root + "/photos/locked"
    try box.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? box.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

    let result = box.flatlink("photos", "flat")
    #expect(result.status == 1)
    #expect(result.err.count == 1 && result.err[0].hasPrefix("unreadable: \(locked): "))
    #expect(result.out == ["link  open__a.jpg", "\ncreated 1, kept 0, skipped 0, pruned 0, failed 1  ->  \(box.root)/flat"])
}

@Test func findingNothingExitsWith1AndSaysWhatWasLookedFor() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg", "empty/notes.txt")

    let none = box.flatlink("empty", "flat")
    #expect(none.status == 1 && none.err == ["flatlink: no images found under \(box.root)/empty"])

    let typo = box.flatlink("--ext", "cr3,jpeg", "photos", "flat")
    #expect(typo.status == 1 && typo.err == ["flatlink: no .cr3, .jpeg files found under \(box.root)/photos"])

    let unknown = box.flatlink("--ext", "raw", "--ext", "jpg", "photos", "flat")
    #expect(unknown.status == 0 && unknown.out.first == "link  a.jpg")
    #expect(unknown.err == ["flatlink: note: .raw is not an image format flatlink knows; linking it all the same"])
}

@Test func aLinkFolderThatCannotBeUsedExitsWith1() throws {
    let box = try Sandbox()
    try box.touch("photos/a.jpg", "file.jpg", "vol/photos/b.jpg")
    for arguments in [["photos", "file.jpg"], ["-n", "photos", "file.jpg"]] {
        var err: [String] = []
        let status = run(arguments, version: "9.9.9", directory: box.root, out: { _ in }, err: { err.append($0) })
        #expect(status == 1 && err == ["flatlink: error: dest can't be used, this is not a folder: \(box.root)/file.jpg"])
    }

    // An unplugged drive's empty mount point: --prune must refuse, and not as a usage error.
    #expect(box.flatlink("vol/photos", "flat").status == 0)
    try box.fm.removeItem(atPath: box.root + "/vol/photos/b.jpg")
    let refused = box.flatlink("--prune", "vol/photos", "flat")
    #expect(refused.status == 1 && refused.out.isEmpty && refused.err.count == 1)
    #expect(refused.err[0].hasPrefix("flatlink: error: no images found under \(box.root)/vol/photos, so --prune would remove"))
    #expect(box.links(in: "flat") == ["b.jpg"])
}
