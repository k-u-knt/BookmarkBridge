import Foundation
import Testing
@testable import SyncCore

@Suite struct SyncEngineTests {
    struct Rig {
        let a = FakeAdapter(name: "Safari")
        let b = FakeAdapter(name: "Chrome")
        let store = StateStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("bb-engine-\(UUID().uuidString)"))
        var engine: SyncEngine { SyncEngine(a: a, b: b, store: store) }

        /// Safari has a folder and two bookmarks, Chrome has one unrelated bookmark; Safari is the source.
        static func setUp() async throws -> Rig {
            let rig = Rig()
            let f = rig.a.add("Folder", folder: true)
            rig.a.add("one", to: f)
            rig.a.add("two")
            rig.b.add("chrome-only")
            try await rig.engine.setUp(source: .a)
            return rig
        }
    }

    @Test func setUpCopiesSourceOntoDestination() async throws {
        let rig = try await Rig.setUp()
        #expect(shape(rig.b.tree) == shape(rig.a.tree))
        #expect(shape(rig.b.tree).contains("chrome-only") == false)
        #expect(rig.engine.isSetUp)
        #expect(rig.store.listBackups().count == 1)
    }

    @Test func setUpRefusesAnEmptySource() async throws {
        let rig = Rig()
        rig.b.add("chrome-only")
        await #expect(throws: SyncError.self) { try await rig.engine.setUp(source: .a) }
        #expect(rig.b.tree.bookmarkCount == 1)
    }

    @Test func syncBeforeSetUpThrows() async throws {
        let rig = Rig()
        await #expect(throws: SyncError.self) { _ = try await rig.engine.sync(prefer: .a) }
    }

    @Test func changesOnEitherSideReachTheOther() async throws {
        let rig = try await Rig.setUp()
        rig.a.add("from-safari")
        rig.b.rename("two", to: "TWO")
        rig.b.remove("one")
        let outcome = try await rig.engine.sync(prefer: .a)
        guard case .synced = outcome else { Issue.record("expected .synced, got \(outcome)"); return }
        #expect(shape(rig.a.tree) == shape(rig.b.tree))
        let s = shape(rig.a.tree)
        #expect(s.contains("from-safari") && s.contains("TWO") && !s.contains("one<"))
    }

    @Test func secondSyncFindsNothingToDo() async throws {
        let rig = try await Rig.setUp()
        rig.a.add("x")
        _ = try await rig.engine.sync(prefer: .a)
        #expect(try await rig.engine.sync(prefer: .a) == .noChanges)
        #expect(try await rig.engine.sync(prefer: .b) == .noChanges)
    }

    @Test func sameBookmarkEditedOnBothSidesFollowsPreferredSideWithoutDuplicates() async throws {
        let rig = try await Rig.setUp()
        let before = rig.a.tree.bookmarkCount
        rig.a.rename("two", to: "safari-name")
        rig.b.rename("two", to: "chrome-name")
        _ = try await rig.engine.sync(prefer: .b)
        #expect(shape(rig.a.tree) == shape(rig.b.tree))
        #expect(shape(rig.a.tree).contains("chrome-name"))
        #expect(rig.a.tree.bookmarkCount == before && rig.b.tree.bookmarkCount == before)
    }

    @Test func unavailableBrowserMeansNothingChanges() async throws {
        let rig = try await Rig.setUp()
        rig.b.isAvailable = false
        rig.a.add("waiting")
        let chromeBefore = rig.b.tree
        #expect(try await rig.engine.sync(prefer: .a) == .unavailable("Chrome"))
        #expect(rig.b.tree == chromeBefore)
        rig.b.isAvailable = true
        _ = try await rig.engine.sync(prefer: .a)
        #expect(shape(rig.b.tree).contains("waiting"))
    }

    @Test func emptyTreeFromABrowserAbortsInsteadOfDeletingEverything() async throws {
        let rig = try await Rig.setUp()
        let chromeBefore = rig.b.tree
        rig.a.tree = Tree.empty(barID: rig.a.tree.root(.bar), otherID: rig.a.tree.root(.other))
        await #expect(throws: SyncError.self) { _ = try await rig.engine.sync(prefer: .a) }
        #expect(rig.b.tree == chromeBefore)
    }

    @Test func largeRemovalNeedsConfirmation() async throws {
        let rig = Rig()
        for i in 0..<40 { rig.a.add("bm\(i)") }
        try await rig.engine.setUp(source: .a)
        for i in 0..<30 { rig.a.remove("bm\(i)") }
        let chromeBefore = rig.b.tree
        #expect(try await rig.engine.sync(prefer: .a) == .needsConfirmation(removals: 30, on: "Chrome"))
        #expect(rig.b.tree == chromeBefore)
        _ = try await rig.engine.sync(prefer: .a, confirmedRemovals: 30)
        #expect(rig.b.tree.bookmarkCount == 10)
    }

    @Test func aBrowserThatDropsOurWritesDoesNotCauseDeletionsElsewhere() async throws {
        let rig = try await Rig.setUp()
        rig.b.add("new-in-chrome")
        rig.a.ignoresWrites = true
        await #expect(throws: SyncError.self) { _ = try await rig.engine.sync(prefer: .b) }
        _ = try? await rig.engine.sync(prefer: .a)
        #expect(shape(rig.b.tree).contains("new-in-chrome"))
        rig.a.ignoresWrites = false
        _ = try await rig.engine.sync(prefer: .a)
        #expect(shape(rig.a.tree) == shape(rig.b.tree))
        #expect(rig.a.tree.nodes.values.filter { $0.title == "new-in-chrome" }.count == 1)
    }

    @Test func activityRecordsWhatMoved() async throws {
        let rig = try await Rig.setUp()
        rig.a.add("fresh")
        _ = try await rig.engine.sync(prefer: .a)
        let latest = try #require(try rig.store.load()?.activity.first)
        #expect(latest.summary == "Added “fresh” · Safari → Chrome")
    }

    @Test func restorePutsEachBrowserBackAndTurnsSyncOff() async throws {
        let rig = Rig()
        rig.a.add("safari-original")
        rig.b.add("chrome-original")
        let safariBefore = shape(rig.a.tree), chromeBefore = shape(rig.b.tree)
        try await rig.engine.setUp(source: .a)
        let backup = try #require(rig.store.listBackups().last)
        try await rig.engine.restore(backup: backup)
        #expect(shape(rig.a.tree) == safariBefore)
        #expect(shape(rig.b.tree) == chromeBefore)
        #expect(rig.engine.isSetUp == false)
    }

    // MARK: Review fixes

    @Test func browserThatRewritesURLsStillSetsUpAndConverges() async throws {
        let rig = Rig()
        rig.b.normalizesURLs = true
        rig.a.tree.nodes["s1"] = Node(id: "s1", title: "bare", url: "https://example.com")
        rig.a.tree.nodes[rig.a.bar]!.children.append("s1")
        try await rig.engine.setUp(source: .a)
        #expect(rig.engine.isSetUp)
        #expect(rig.a.tree.nodes["s1"]?.url == "https://example.com/")     // the stored form flows back
        #expect(try await rig.engine.sync(prefer: .a) == .noChanges)
    }

    @Test func rewrittenURLDuringSyncDoesNotWedge() async throws {
        let rig = try await Rig.setUp()
        rig.b.normalizesURLs = true
        let id = rig.a.add("bare")
        rig.a.tree.nodes[id]!.url = "https://bare.example"
        _ = try await rig.engine.sync(prefer: .a)
        #expect(shape(rig.a.tree) == shape(rig.b.tree))
        #expect(try await rig.engine.sync(prefer: .a) == .noChanges)
    }

    @Test func droppedConnectionMidWriteDoesNotDuplicate() async throws {
        let rig = try await Rig.setUp()
        let f = rig.a.add("NewFolder", folder: true)
        rig.a.add("g1", to: f)
        rig.a.add("g2")
        rig.a.add("g2")                                   // identical twin
        rig.b.failAfterOps = 3
        await #expect(throws: (any Error).self) { _ = try await rig.engine.sync(prefer: .a) }
        _ = try await rig.engine.sync(prefer: .a)
        _ = try await rig.engine.sync(prefer: .a)
        #expect(shape(rig.a.tree) == shape(rig.b.tree))
        for (title, n) in [("NewFolder", 1), ("g1", 1), ("g2", 2)] {
            #expect(rig.a.tree.nodes.values.filter { $0.title == title }.count == n, "\(title) in Safari")
            #expect(rig.b.tree.nodes.values.filter { $0.title == title }.count == n, "\(title) in Chrome")
        }
    }

    @Test func failedRoundsDoNotPileUpBackups() async throws {
        let rig = try await Rig.setUp()
        rig.b.add("x")
        rig.a.ignoresWrites = true
        let before = rig.store.listBackups().count
        for _ in 0..<3 { _ = try? await rig.engine.sync(prefer: .b) }
        #expect(rig.store.listBackups().count == before + 1)
    }

    @Test func backupsIncludeTheAdaptersRawFiles() async throws {
        let rig = Rig()
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).plist")
        try Data("raw".utf8).write(to: raw)
        rig.a.backupFiles = [raw]
        rig.a.add("x")
        try await rig.engine.setUp(source: .a)
        let backup = try #require(rig.store.listBackups().first)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent(raw.lastPathComponent).path))
    }

    @Test func setupBackupSurvivesRotation() async throws {
        let rig = try await Rig.setUp()
        let setupBackup = try #require(rig.store.listBackups().last)
        for i in 0..<55 {
            rig.a.add("n\(i)")
            _ = try await rig.engine.sync(prefer: .a)
        }
        #expect(rig.store.listBackups().contains(setupBackup))
        #expect(rig.store.listBackups().count == 51)
    }

    @Test func confirmationCoversOnlyTheNumberThatWasShown() async throws {
        let rig = Rig()
        for i in 0..<80 { rig.a.add("bm\(i)") }
        try await rig.engine.setUp(source: .a)
        for i in 0..<30 { rig.a.remove("bm\(i)") }
        #expect(try await rig.engine.sync(prefer: .a) == .needsConfirmation(removals: 30, on: "Chrome"))
        for i in 30..<60 { rig.a.remove("bm\(i)") }
        #expect(try await rig.engine.sync(prefer: .a, confirmedRemovals: 30) == .needsConfirmation(removals: 60, on: "Chrome"))
        #expect(rig.b.tree.bookmarkCount == 80)
    }

    @Test func changedRootFolderStopsTheSync() async throws {
        let rig = try await Rig.setUp()
        // Chrome now reports a different folder as its bookmarks bar (e.g. after signing in).
        var t = Tree.empty(barID: "Chrome-bar2", otherID: rig.b.tree.root(.other))
        t.nodes["z"] = Node(id: "z", title: "account-bookmark", url: "https://z.example")
        t.nodes["Chrome-bar2"]!.children = ["z"]
        rig.b.tree = t
        let safariBefore = rig.a.tree
        await #expect(throws: SyncError.rootsChanged("Chrome")) { _ = try await rig.engine.sync(prefer: .b) }
        #expect(rig.a.tree == safariBefore)
    }

    @Test func differentBrowserProfileStopsTheSync() async throws {
        let rig = Rig()
        rig.a.add("x")
        rig.b.identity = "profile-1"
        try await rig.engine.setUp(source: .a)
        rig.b.identity = "profile-2"
        rig.b.rename("x", to: "from another profile")
        await #expect(throws: SyncError.differentProfile("Chrome")) { _ = try await rig.engine.sync(prefer: .b) }
        #expect(shape(rig.a.tree).contains("from another profile") == false)
    }

    @Test func restoreThatFailsHalfWayStillTurnsSyncOff() async throws {
        let rig = Rig()
        rig.a.add("safari-original")
        rig.b.add("chrome-original")
        try await rig.engine.setUp(source: .a)
        let backup = try #require(rig.store.listBackups().last)
        rig.b.failAfterOps = 0
        await #expect(throws: (any Error).self) { try await rig.engine.restore(backup: backup) }
        #expect(rig.engine.isSetUp == false)
    }
}
