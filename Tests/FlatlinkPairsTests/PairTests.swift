import Foundation
import Testing
@testable import FlatlinkPairs

// MARK: A new pair writes nothing by itself

@Test func aNewPairDoesNotUpdateByItself() {
    let pair = Pair(source: "/Users/me/Pictures/Photos", dest: Pair.suggestedDest(for: "/Users/me/Pictures/Photos"))
    #expect(pair.isReady)
    #expect(!pair.watch)
    #expect(pair.watched == nil)
}

@Test func aPairSavedWithoutTheSwitchDoesNotUpdateByItself() throws {
    let json = #"{"id":"6B1F2C3D-0000-4000-8000-000000000001","source":"/p","dest":"/d"}"#
    let pair = try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
    #expect(!pair.watch)
}

@Test func aPairWithTheSwitchOnIsWatched() {
    var pair = Pair(source: "/p", dest: "/d")
    pair.watch = true
    #expect(pair.watched == WatchedFolders(source: "/p", dest: "/d"))
}

// MARK: The suggested link folder

@Test func theLinkFolderGoesBesideThePhotos() {
    #expect(Pair.suggestedDest(for: "/Users/me/Pictures/Photos") == "/Users/me/Pictures/PhotoLab-All")
    #expect(Pair.suggestedDest(for: "/Volumes/Photos/2026") == "/Volumes/Photos/PhotoLab-All")
}

@Test func theLinkFolderGoesInsideADrivesTopFolder() {
    // Beside it would be /Volumes/PhotoLab-All: not on the drive, and not writable.
    #expect(Pair.suggestedDest(for: "/Volumes/Photos") == "/Volumes/Photos/PhotoLab-All")
    #expect(Pair.suggestedDest(for: "/Volumes/Photos/") == "/Volumes/Photos/PhotoLab-All")
    #expect(Pair.suggestedDest(for: "/Photos") == "/Photos/PhotoLab-All")
}

@Test func theLinkFolderGoesInsideAMountPointWherever() {
    // The startup drive is mounted at /, so / is a drive's top folder that exists on every Mac.
    #expect(Pair.suggestedDest(for: "/") == "/PhotoLab-All")
    let temporary = NSTemporaryDirectory() + "flatlink-" + UUID().uuidString
    #expect(Pair.suggestedDest(for: temporary) == (NSTemporaryDirectory() as NSString).appendingPathComponent("PhotoLab-All"))
}

// MARK: Drives coming and going

@Test func aDrivesTopFolderIsOnTheDrive() {
    #expect(Pair(source: "/Volumes/Photos").isOnVolume("/Volumes/Photos"))
    #expect(Pair(source: "/Volumes/Photos/2026").isOnVolume("/Volumes/Photos"))
    #expect(!Pair(source: "/Volumes/Photos 2").isOnVolume("/Volumes/Photos"))
    #expect(!Pair(source: "/Volumes/PhotosBackup/2026").isOnVolume("/Volumes/Photos"))
    #expect(Pair(source: "/Users/me").isOnVolume("/"))
}

// MARK: Saving

private func pair(_ source: String) -> Pair {
    var pair = Pair(source: source, dest: source + "-links")
    pair.watch = true
    pair.prune = true
    return pair
}

@Test func savedPairsReadBackAsTheyWere() throws {
    let saved = SavedPairs(pairs: [pair("/a"), pair("/b")])
    let read = try #require(SavedPairs(decoding: try saved.encoded()))
    #expect(read.pairs == saved.pairs)
    #expect(read.unreadable.isEmpty)
}

@Test func oneUnreadableEntryDoesNotLoseTheOthers() throws {
    let good = try JSONEncoder().encode(pair("/a"))
    let json = "[\(String(decoding: good, as: UTF8.self)),{\"id\":\"not a uuid\",\"source\":3},\"junk\"]"
    let read = try #require(SavedPairs(decoding: Data(json.utf8)))
    #expect(read.pairs.map(\.source) == ["/a"])
    #expect(read.unreadable.count == 2)
}

@Test func unreadableEntriesAreSavedBackUnchanged() throws {
    let newer = #"{"id":"6B1F2C3D-0000-4000-8000-000000000002","source":{"bookmark":"AAAA"},"dest":"/d","future":true}"#
    let json = "[\(String(decoding: try JSONEncoder().encode(pair("/a")), as: UTF8.self)),\(newer)]"
    var read = try #require(SavedPairs(decoding: Data(json.utf8)))
    read.pairs.append(pair("/b"))

    let again = try #require(SavedPairs(decoding: try read.encoded()))
    #expect(again.pairs.map(\.source) == ["/a", "/b"])
    #expect(again.unreadable.count == 1)
    let kept = try #require(try JSONSerialization.jsonObject(with: again.unreadable[0]) as? [String: Any])
    #expect(kept["future"] as? Bool == true)
    #expect((kept["source"] as? [String: Any])?["bookmark"] as? String == "AAAA")
}

@Test func somethingThatIsNotAListIsNotReadAsAnEmptyOne() {
    #expect(SavedPairs(decoding: Data("{\"pairs\":[]}".utf8)) == nil)
    #expect(SavedPairs(decoding: Data("not json".utf8)) == nil)
    #expect(SavedPairs(decoding: Data()) == nil)
}

@Test func anEmptyListIsEmpty() throws {
    let read = try #require(SavedPairs(decoding: Data("[]".utf8)))
    #expect(read.pairs.isEmpty && read.unreadable.isEmpty)
    #expect(try SavedPairs().encoded() == Data("[]".utf8))
}

// MARK: Choosing another photo folder

@Test func theSuggestedLinkFolderFollowsANewPhotoFolder() {
    let old = "/nonexistent-\(UUID().uuidString)/Photos"
    let new = "/nonexistent-\(UUID().uuidString)/Pictures/Photos"
    #expect(Pair.dest(Pair.suggestedDest(for: old), afterSourceMovedFrom: old, to: new) == Pair.suggestedDest(for: new))
    #expect(Pair.dest("", afterSourceMovedFrom: "", to: new) == Pair.suggestedDest(for: new))
}

@Test func aChosenOrUsedLinkFolderStaysWithANewPhotoFolder() throws {
    let new = "/nonexistent-\(UUID().uuidString)/Photos"
    // Chosen by the user.
    #expect(Pair.dest("/Users/me/Links", afterSourceMovedFrom: "/Users/me/Photos", to: new) == "/Users/me/Links")
    // The suggestion, but links and edits have been made there.
    let root = NSTemporaryDirectory() + "flatlink-dest-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    let old = root + "/Photos"
    try FileManager.default.createDirectory(atPath: Pair.suggestedDest(for: old), withIntermediateDirectories: true)
    #expect(Pair.dest(Pair.suggestedDest(for: old), afterSourceMovedFrom: old, to: new) == Pair.suggestedDest(for: old))
    // Nothing chosen yet.
    #expect(Pair.dest("/Users/me/Links", afterSourceMovedFrom: old, to: "") == "/Users/me/Links")
}
