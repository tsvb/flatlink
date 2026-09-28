import Foundation
import Testing
import FlatlinkCore
@testable import FlatlinkPairs

@MainActor
@Test func forgettingARunEndsTheUpdateThatWasDue() {
    let run = Run()
    let pair = Pair(source: "/nonexistent-\(UUID().uuidString)", dest: "/nonexistent-links")
    run.startWatching { pair }
    // The catch-up update is due, so App Nap is held off until it has run.
    #expect(run.watch == .watching && run.isKeepingAwake)

    run.forget()
    #expect(run.watch == .off)
    #expect(!run.isKeepingAwake)
}

@MainActor
@Test func cancellingLeavesADueUpdateGoingAhead() {
    // What removing a pair used to do: its run was let go with App Nap still held off.
    let run = Run()
    let pair = Pair(source: "/nonexistent-\(UUID().uuidString)", dest: "/nonexistent-links")
    run.startWatching { pair }
    run.cancel()
    #expect(run.isKeepingAwake)
    run.forget()
    #expect(!run.isKeepingAwake)
}

// MARK: One run at a time in a link folder

/// A photo folder of `count` images and a link folder beside it, removed when the test ends.
private final class Folders {
    let root = canonicalPath(NSTemporaryDirectory() + "flatlink-run-" + UUID().uuidString)
    var source: String { root + "/Photos" }
    var dest: String { root + "/PhotoLab-All" }

    init(count: Int) throws {
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        for i in 0..<count { FileManager.default.createFile(atPath: source + "/\(i).jpg", contents: nil) }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var links: Int { (try? FileManager.default.contentsOfDirectory(atPath: dest).count) ?? 0 }
}

@MainActor
private func finished(_ run: Run) async throws -> Outcome {
    for _ in 0..<500 {
        switch run.phase {
        case .finished(let outcome): return outcome
        case .failed(let message): Issue.record("failed: \(message)"); throw CancellationError()
        case .idle, .scanning: try await Task.sleep(for: .milliseconds(20))
        }
    }
    Issue.record("the run did not finish")
    throw CancellationError()
}

@MainActor
@Test func twoPairsWithOneLinkFolderUpdateOneAfterTheOther() async throws {
    let folders = try Folders(count: 300)
    let pair = Pair(source: folders.source, dest: folders.dest)
    let first = Run(), second = Run()
    first.update(pair)
    second.update(pair)

    let one = try await finished(first), two = try await finished(second)
    // Side by side, both would plan the same 300 links and the second would fail to make each one.
    #expect(one.issues.isEmpty && two.issues.isEmpty)
    #expect(one.linked.count + two.linked.count == 300)
    #expect(folders.links == 300)
}

@MainActor
@Test func anUpdateAfterACancelledOneWaitsForItAndFinishesTheJob() async throws {
    let folders = try Folders(count: 300)
    let pair = Pair(source: folders.source, dest: folders.dest)
    let run = Run()
    run.update(pair)
    run.cancel()
    #expect(!run.isBusy)
    run.update(pair)

    let outcome = try await finished(run)
    #expect(outcome.issues.isEmpty)
    #expect(folders.links == 300)
}
