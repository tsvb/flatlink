import Foundation
import Testing
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

// MARK: What needs a look

@MainActor
private func settled(_ run: Run) async throws {
    for _ in 0..<500 where run.isBusy { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!run.isBusy)
}

@MainActor
@Test func aRunThatFailsOrLeavesPhotosOutNeedsAttention() async throws {
    let root = NSTemporaryDirectory() + "flatlink-attention-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/Photos/a", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root + "/Photos/a/b.jpg", contents: nil)

    let run = Run()
    #expect(!run.needsAttention)
    run.update(Pair(source: root + "/Photos", dest: root + "/PhotoLab-All"))
    try await settled(run)
    #expect(run.outcome?.linked.count == 1 && !run.needsAttention)

    // Another photo wants the same link name: it is left out, and says so.
    FileManager.default.createFile(atPath: root + "/Photos/a__b.jpg", contents: nil)
    run.update(Pair(source: root + "/Photos", dest: root + "/PhotoLab-All"))
    try await settled(run)
    #expect(run.outcome?.issues.count == 1 && run.needsAttention)

    run.update(Pair(source: root + "/Missing", dest: root + "/PhotoLab-All"))
    try await settled(run)
    guard case .failed = run.phase else { Issue.record("expected a failure, got \(run.phase)"); return }
    #expect(run.needsAttention)
}

@MainActor
@Test func aFolderThatCannotBeWatchedSaysSo() {
    let run = Run()
    run.startWatching { Pair(source: "/nonexistent-\(UUID().uuidString)", dest: "/nonexistent-links") }
    run.couldNotWatch()
    #expect(run.watch == .off && !run.isKeepingAwake)
    guard case .failed(let message) = run.phase else { Issue.record("expected a failure, got \(run.phase)"); return }
    #expect(message.contains("can't watch"))
    #expect(run.needsAttention)
}
