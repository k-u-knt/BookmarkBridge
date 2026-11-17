import Foundation
import Testing
@testable import SafariAdapter
@testable import SyncCore

@Suite struct SafariAdapterTests {
    static func leaf(_ title: String, uuid: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            "URIDictionary": ["title": title],
            "URLString": "https://example.com/\(title)",
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": uuid ?? "U-\(title)",
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    static func list(_ title: String, _ children: [[String: Any]], uuid: String? = nil) -> [String: Any] {
        ["Title": title, "Children": children, "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid ?? "U-\(title)"]
    }

    /// Shaped like Safari's own file: a History proxy, Favorites, Bookmarks Menu, Reading List, loose items.
    static func fixture() throws -> URL {
        let root: [String: Any] = [
            "Title": "",
            "WebBookmarkFileVersion": 1,
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": "U-root",
            "Sync": ["ServerData": Data([1, 2, 3])],
            "Children": [
                ["Title": "History", "WebBookmarkIdentifier": "History", "WebBookmarkType": "WebBookmarkTypeProxy", "WebBookmarkUUID": "U-history"],
                list("BookmarksBar", [leaf("fav1", extra: ["Sync": ["Key": "k1"]]), list("FavFolder", [leaf("inner")]), leaf("fav2")]),
                list("BookmarksMenu", [leaf("menu1")]),
                list("com.apple.ReadingList", [leaf("readlater", extra: ["ReadingList": ["DateAdded": Date(timeIntervalSince1970: 0)]])]),
                list("LooseFolder", [leaf("deep")]),
                leaf("loose1"),
            ],
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-safari-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        return url
    }

    static func raw(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    }

    let ex = "https://example.com/"

    @Test func readMapsFavoritesMenuAndLooseItemsAndSkipsReadingListAndHistory() async throws {
        let tree = try await SafariAdapter(plistURL: Self.fixture()).read()
        try tree.validate()
        #expect(shape(tree) == "bar:[fav1<\(ex)fav1>,FavFolder[inner<\(ex)inner>],fav2<\(ex)fav2>] other:[menu1<\(ex)menu1>,LooseFolder[deep<\(ex)deep>],loose1<\(ex)loose1>]")
        #expect(tree.root(.bar) == "U-BookmarksBar")
        #expect(tree.nodes["U-fav1"]?.title == "fav1")
    }

    @Test func createUsesTempIDsWithinABatchAndReturnsRealOnes() async throws {
        let adapter = SafariAdapter(plistURL: try Self.fixture())
        let created = try await adapter.apply([
            .create(tempID: "tmpF", parent: "U-BookmarksBar", index: 0, title: "NewFolder", url: nil),
            .create(tempID: "tmpB", parent: "tmpF", index: 0, title: "child", url: "https://c.example"),
        ])
        let tree = try await adapter.read()
        #expect(shape(tree).hasPrefix("bar:[NewFolder[child<https://c.example>],fav1"))
        #expect(tree.nodes[created["tmpF"]!]?.title == "NewFolder")
        #expect(tree.nodes[created["tmpB"]!]?.url == "https://c.example")
    }

    @Test func updateMoveAndRemove() async throws {
        let adapter = SafariAdapter(plistURL: try Self.fixture())
        _ = try await adapter.apply([
            .update(id: "U-fav1", title: "renamed", url: "https://new.example"),
            .update(id: "U-FavFolder", title: "Folder2", url: nil),
            .move(id: "U-fav2", parent: "U-FavFolder", index: 0),
            .remove(id: "U-LooseFolder"),
        ])
        #expect(shape(try await adapter.read()) == "bar:[renamed<https://new.example>,Folder2[fav2<\(ex)fav2>,inner<\(ex)inner>]] other:[menu1<\(ex)menu1>,loose1<\(ex)loose1>]")
    }

    @Test func randomEditsRoundTripThroughTheFile() async throws {
        let adapter = SafariAdapter(plistURL: try Self.fixture())
        var rng = SeededRNG(seed: 7)
        for i in 0..<40 {
            let current = try await adapter.read()
            let target = RandomTrees.mutate(current, prefix: "r\(i)_", rng: &rng)
            _ = try await adapter.apply(diff(from: current, to: target))
            let after = try await adapter.read()
            try after.validate()
            #expect(shape(after) == shape(target), "round \(i)")
        }
    }

    @Test func writingKeepsEverythingTheAdapterDoesNotUnderstand() async throws {
        let url = try Self.fixture()
        let adapter = SafariAdapter(plistURL: url)
        _ = try await adapter.apply([.update(id: "U-fav1", title: "renamed", url: "\(ex)fav1")])
        let root = try Self.raw(url)
        #expect((root["Sync"] as? [String: Any])?["ServerData"] as? Data == Data([1, 2, 3]))
        #expect(root["WebBookmarkFileVersion"] as? Int == 1)
        let children = root["Children"] as! [[String: Any]]
        #expect(children[0]["WebBookmarkType"] as? String == "WebBookmarkTypeProxy")
        let readingList = children.first { $0["Title"] as? String == "com.apple.ReadingList" }!
        #expect((readingList["Children"] as! [[String: Any]]).count == 1)
        let fav1 = (children[1]["Children"] as! [[String: Any]])[0]
        #expect((fav1["Sync"] as? [String: String]) == ["Key": "k1"])
        #expect((fav1["URIDictionary"] as? [String: String])?["title"] == "renamed")
    }

    @Test func appendingToOtherLandsInsideBookmarksMenu() async throws {
        let url = try Self.fixture()
        let adapter = SafariAdapter(plistURL: url)
        _ = try await adapter.apply([.create(tempID: "t", parent: SafariAdapter.otherRootID, index: 1, title: "appended", url: "https://x.example")])
        let children = try Self.raw(url)["Children"] as! [[String: Any]]
        let menu = children.first { $0["Title"] as? String == "BookmarksMenu" }!
        let titles = (menu["Children"] as! [[String: Any]]).map { ($0["URIDictionary"] as? [String: String])?["title"] }
        #expect(titles == ["menu1", "appended"])
        #expect(shape(try await adapter.read()).contains("other:[menu1<\(ex)menu1>,appended<https://x.example>,LooseFolder"))
    }

    @Test func itemsThatCannotSyncAreSkippedAndDoNotShiftPositions() async throws {
        let url = try Self.fixture()
        var root = try Self.raw(url)
        var children = root["Children"] as! [[String: Any]]
        var bar = children[1]
        var barKids = bar["Children"] as! [[String: Any]]
        var blank = Self.leaf("blank")
        blank["URLString"] = ""
        barKids.insert(blank, at: 1)                      // fav1, (blank), FavFolder, fav2
        bar["Children"] = barKids
        children[1] = bar
        root["Children"] = children
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)

        let adapter = SafariAdapter(plistURL: url)
        #expect(shape(try await adapter.read()).contains("blank") == false)
        _ = try await adapter.apply([.create(tempID: "t", parent: "U-BookmarksBar", index: 2, title: "new", url: "https://n.example")])
        #expect(shape(try await adapter.read()).hasPrefix("bar:[fav1<\(ex)fav1>,FavFolder[inner<\(ex)inner>],new<https://n.example>,fav2"))
    }

    @Test func missingFileIsUnavailableAndReadThrows() async throws {
        let adapter = SafariAdapter(plistURL: URL(fileURLWithPath: "/nonexistent/Bookmarks.plist"))
        #expect(adapter.isAvailable == false)
        await #expect(throws: (any Error).self) { _ = try await adapter.read() }
    }

    @Test func garbageFileThrowsInsteadOfReadingAsEmpty() async throws {
        let url = try Self.fixture()
        try Data("not a plist".utf8).write(to: url)
        await #expect(throws: (any Error).self) { _ = try await SafariAdapter(plistURL: url).read() }
    }

    @Test func outsideChangesFireOnChangeButOwnWritesDoNot() async throws {
        let url = try Self.fixture()
        let adapter = SafariAdapter(plistURL: url, pollInterval: 0.05)
        let counter = Counter()
        adapter.onChange = { counter.bump() }
        adapter.startWatching()
        _ = try await adapter.apply([.update(id: "U-fav1", title: "mine", url: "\(ex)fav1")])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(counter.value == 0)
        var root = try Self.raw(url)
        root["Title"] = "touched"
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(counter.value == 1)
        adapter.stopWatching()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
