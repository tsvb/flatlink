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
