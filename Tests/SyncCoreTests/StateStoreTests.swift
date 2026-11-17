import Foundation
import Testing
@testable import SyncCore

@Suite struct StateStoreTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bb-test-\(UUID().uuidString)")
    }

    @Test func loadIsNilBeforeAnythingIsSaved() throws {
        #expect(try StateStore(directory: tempDir()).load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = StateStore(directory: tempDir())
        let state = SyncState(
            base: T.tree(bar: [.b("x")]),
            idMaps: ["Safari": ["x": "S-1"], "Chrome": ["x": "42"]],
            activity: [ActivityEntry(date: Date(timeIntervalSince1970: 1), summary: "Added “x”")]
        )
        try store.save(state)
        let loaded = try #require(try store.load())
        #expect(loaded.base == state.base)
        #expect(loaded.idMaps == state.idMaps)
        #expect(loaded.activity.map(\.summary) == ["Added “x”"])
    }

    @Test func backupsArePrunedToFifty() throws {
        let store = StateStore(directory: tempDir())
        for _ in 0..<51 { _ = try store.writeBackup(trees: ["Safari": T.tree()], extraFiles: []) }
        #expect(store.listBackups().count == 50)
    }

    @Test func backupHoldsTreesAndExtraFilesAndListsNewestFirst() throws {
        let dir = tempDir()
        let store = StateStore(directory: dir)
        let extra = dir.appendingPathComponent("extra.plist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: extra)
        let first = try store.writeBackup(trees: ["Safari": T.tree(bar: [.b("x")])], extraFiles: [extra])
        let second = try store.writeBackup(trees: ["Safari": T.tree()], extraFiles: [])
        #expect(store.listBackups().map(\.lastPathComponent) == [second.lastPathComponent, first.lastPathComponent])
        #expect(try store.readBackup(first)["Safari"] == T.tree(bar: [.b("x")]))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("extra.plist").path))
    }

    @Test func resetForgetsStateButKeepsBackups() throws {
        let store = StateStore(directory: tempDir())
        try store.save(SyncState(base: T.tree(), idMaps: [:], activity: []))
        _ = try store.writeBackup(trees: ["Safari": T.tree()], extraFiles: [])
        try store.reset()
        #expect(try store.load() == nil)
        #expect(store.listBackups().count == 1)
    }
}
