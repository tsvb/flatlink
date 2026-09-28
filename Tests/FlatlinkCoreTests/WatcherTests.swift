import CoreServices
import Foundation
import os
import Testing
@testable import FlatlinkCore

private let created = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
private let removed = kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile
private let modified = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile

@Test func onlyImagesAndFoldersComingOrGoingCallForARun() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/src/_flat")) { _ in }
    let src = t.root + "/src"

    #expect(watcher.isRelevant(src + "/2026/IMG_0001.CR3", flags: created))
    #expect(watcher.isRelevant(src + "/2026/IMG_0001.cr3", flags: removed))
    #expect(watcher.isRelevant(src + "/2026/IMG_0001.CR3", flags: kFSEventStreamEventFlagItemRenamed))
    #expect(watcher.isRelevant(src + "/2026", flags: kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir))

    #expect(!watcher.isRelevant(src + "/a.jpg", flags: modified), "an edit keeps the link")
    #expect(!watcher.isRelevant(src + "/2026/notes.txt", flags: created))
    #expect(!watcher.isRelevant(src + "/Session/CaptureOne/Cache/IMG.cof", flags: created))
    #expect(!watcher.isRelevant(src + "/.hidden/IMG.CR3", flags: created))
    #expect(!watcher.isRelevant(src + "/2026/._IMG.CR3", flags: created))
    #expect(!watcher.isRelevant(src + "/_flat/a.jpg", flags: created | kFSEventStreamEventFlagItemIsSymlink))
    #expect(!watcher.isRelevant(src + "/_flat/a.jpg.dop", flags: created), "PhotoLab's sidecars beside the links")
    #expect(!watcher.isRelevant(src + "/_flat", flags: created | kFSEventStreamEventFlagItemIsDir))
    #expect(!watcher.isRelevant(src + "/album", flags: created | kFSEventStreamEventFlagItemIsSymlink))
    #expect(!watcher.isRelevant(t.root + "/srcother/a.jpg", flags: created))
    #expect(!watcher.isRelevant(t.root + "/elsewhere.jpg", flags: created))
}

@Test func packageContentsNeverCallForARun() throws {
    let t = try Tree()
    try t.touch("src/Photos Library.photoslibrary/originals/0/IMG.HEIC", "src/2026.05/IMG.jpg")
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")) { _ in }
    #expect(!watcher.isRelevant(t.root + "/src/Photos Library.photoslibrary/originals/0/IMG.HEIC", flags: created))
    #expect(watcher.isRelevant(t.root + "/src/2026.05/IMG.jpg", flags: created), "a dot doesn't make a package")
}

@Test func theExtensionFilterDecidesWhichImagesCount() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    var options = FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")
    options.extensions = ["cr3"]
    let watcher = SourceWatcher(options) { _ in }
    #expect(watcher.isRelevant(t.root + "/src/IMG.CR3", flags: created))
    #expect(!watcher.isRelevant(t.root + "/src/IMG.JPG", flags: created))
}

/// Starts a watcher on a tree made just before. FSEvents numbers an event when it gets to it, not when the
/// file changed, so the making of the tree can still arrive after a start "since now" — later on a busy
/// machine. It is waited out and forgotten, so that a test sees only what it does itself.
private func startSettled(_ watcher: SourceWatcher, _ changes: OSAllocatedUnfairLock<[SourceChange]>) async throws {
    try await Task.sleep(for: .seconds(1))
    #expect(watcher.start())
    try await Task.sleep(for: .seconds(1))
    changes.withLock { $0 = [] }
}

/// Waits for FSEvents, which delivers within its latency plus some scheduling slack.
private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Test func aWatcherReportsANewImageButNotTheLinksARunMakes() async throws {
    let t = try Tree()
    try t.touch("src/a.jpg", "src/_flat/old.jpg.dop")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let options = FlattenOptions(source: t.root + "/src", dest: t.root + "/src/_flat")
    let watcher = SourceWatcher(options, latency: 0.1) { change in changes.withLock { $0.append(change) } }
    try await startSettled(watcher, changes)
    defer { watcher.stop() }

    // A run into a link folder inside the source, and other noise: none of it is news.
    _ = try flatten(options)
    try t.touch("src/notes.txt", "src/.hidden.jpg", "src/_flat/a.jpg.dop")
    try await Task.sleep(for: .seconds(1))
    #expect(changes.withLock { $0 }.isEmpty)

    try t.touch("src/2026/IMG_0001.CR3")
    #expect(try await eventually { !changes.withLock { $0 }.isEmpty })
    let reported = changes.withLock { $0 }.flatMap { change -> [String] in
        if case .images(let paths) = change { paths } else { [] }
    }
    #expect(reported.contains(t.root + "/src/2026/IMG_0001.CR3"))
    #expect(reported.allSatisfy { !$0.hasPrefix(t.root + "/src/_flat") })
}

@Test func aWatcherSaysSoWhenTheSourceGoesAndComesBack() async throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat"), latency: 0.1) { change in
        changes.withLock { $0.append(change) }
    }
    try await startSettled(watcher, changes)
    defer { watcher.stop() }

    try t.fm.moveItem(atPath: t.root + "/src", toPath: t.root + "/away")
    #expect(try await eventually { changes.withLock { $0 }.contains(.everything) })
    changes.withLock { $0 = [] }
    try t.fm.moveItem(atPath: t.root + "/away", toPath: t.root + "/src")
    #expect(try await eventually { changes.withLock { $0 }.contains(.everything) })
}

@Test func aStoppedWatcherIsSilent() async throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat"), latency: 0.1) { change in
        changes.withLock { $0.append(change) }
    }
    try await startSettled(watcher, changes)
    watcher.stop()
    let before = changes.withLock { $0 }
    try t.touch("src/b.jpg")
    try await Task.sleep(for: .seconds(1))
    #expect(changes.withLock { $0 } == before)
}

// MARK: When only a full run can tell

@Test func lostEventsMountsAndAMovedSourceCallForAFullRun() throws {
    let t = try Tree()
    try t.touch("src/a.jpg")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat")) { change in
        changes.withLock { $0.append(change) }
    }
    let src = t.root + "/src"
    let wholesale = [
        kFSEventStreamEventFlagMustScanSubDirs,                                          // the system lost count
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped,
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped,
        kFSEventStreamEventFlagRootChanged,                                              // the source moved
        kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount,                   // a drive below it
    ]
    for flag in wholesale {
        changes.withLock { $0 = [] }
        // Even among other events, and whatever they are.
        watcher.received([src + "/b.jpg", src, src + "/notes.txt"], [FSEventStreamEventFlags(created), FSEventStreamEventFlags(flag), 0])
        #expect(changes.withLock { $0 } == [.everything], "flags \(flag)")
    }

    changes.withLock { $0 = [] }
    watcher.received([src + "/b.jpg", src + "/notes.txt"], [FSEventStreamEventFlags(created), FSEventStreamEventFlags(created)])
    #expect(changes.withLock { $0 } == [.images([src + "/b.jpg"])])
    changes.withLock { $0 = [] }
    watcher.received([src + "/notes.txt"], [FSEventStreamEventFlags(created)])
    #expect(changes.withLock { $0 }.isEmpty, "nothing a run would act on")
}

// MARK: Renames

@Test func aRenamedImageIsReportedUnderBothNames() async throws {
    let t = try Tree()
    try t.touch("src/day/IMG_0001.CR3")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat"), latency: 0.1) { change in
        changes.withLock { $0.append(change) }
    }
    try await startSettled(watcher, changes)
    defer { watcher.stop() }

    try t.fm.moveItem(atPath: t.root + "/src/day/IMG_0001.CR3", toPath: t.root + "/src/day/Iceland 001.CR3")
    let reported = { changes.withLock { $0 }.flatMap { change -> [String] in if case .images(let paths) = change { paths } else { [] } } }
    #expect(try await eventually { Set(reported()).isSuperset(of: [t.root + "/src/day/IMG_0001.CR3", t.root + "/src/day/Iceland 001.CR3"]) })
}

@Test func aFolderHiddenOrUnhiddenIsReported() async throws {
    // A folder renamed to a hidden name takes its photos out of the links, and back in when it is renamed back.
    let t = try Tree()
    try t.touch("src/2026/a.jpg")
    let changes = OSAllocatedUnfairLock<[SourceChange]>(initialState: [])
    let watcher = SourceWatcher(FlattenOptions(source: t.root + "/src", dest: t.root + "/flat"), latency: 0.1) { change in
        changes.withLock { $0.append(change) }
    }
    try await startSettled(watcher, changes)
    defer { watcher.stop() }
    let reported = { changes.withLock { $0 }.flatMap { change -> [String] in if case .images(let paths) = change { paths } else { [] } } }

    try t.fm.moveItem(atPath: t.root + "/src/2026", toPath: t.root + "/src/.2026")
    #expect(try await eventually { reported().contains(t.root + "/src/2026") })
    #expect(!reported().contains { $0.hasPrefix(t.root + "/src/.2026") }, "the hidden name itself is not a change to act on")

    changes.withLock { $0 = [] }
    try t.fm.moveItem(atPath: t.root + "/src/.2026", toPath: t.root + "/src/2026")
    #expect(try await eventually { reported().contains(t.root + "/src/2026") })
}
