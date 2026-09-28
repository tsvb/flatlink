import Foundation
import Testing
@testable import FlatlinkCore

// MARK: - Case

@Test func aPhotoRenamedOnlyInCaseKeepsOneLinkWithItsEdits() throws {
    let t = try Tree()
    guard !Volume(of: t.root).caseSensitive else { return }   // the names are two different links there
    try t.touch("src/day/IMG_0001.JPG")
    _ = try t.run()
    try t.touch("flat/day__IMG_0001.JPG.dop")

    // A case-only rename, done the way Finder does it. The link's old spelling still finds the photo on a
    // drive that ignores case, so it is kept as it is: nothing to relink, prune or report.
    try t.fm.moveItem(atPath: t.root + "/src/day/IMG_0001.JPG", toPath: t.root + "/src/day/img_0001.jpg")
    for _ in 0..<2 {
        let (summary, events) = try t.run { $0.prune = true }
        #expect(summary.kept == 1 && summary.created == 0 && summary.relinked == 0, "\(summary)")
        #expect(summary.failed == 0 && summary.skipped == 0 && summary.pruned == 0 && events.isEmpty, "\(events)")
        #expect(Array(t.links(in: "flat").keys) == ["day__IMG_0001.JPG"])
        #expect(isSameFile(t.root + "/flat/day__IMG_0001.JPG", t.root + "/src/day/img_0001.jpg"))
    }
    #expect(t.fm.fileExists(atPath: t.root + "/flat/day__IMG_0001.JPG.dop"))
}
