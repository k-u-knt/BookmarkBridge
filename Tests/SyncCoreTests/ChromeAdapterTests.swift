import Foundation
import Testing
@testable import ChromeAdapter
@testable import SyncCore

/// Plays the extension's part over the socket.
final class FakeExtension: @unchecked Sendable {
    let fd: Int32
    private var reader = FrameReader()

    init(path: String) throws { fd = try UnixSocket.connect(path: path) }
    deinit { close(fd) }

    func receive() throws -> [String: Any] {
        while true {
            if let frame = reader.next() {
                return try JSONSerialization.jsonObject(with: frame) as! [String: Any]
            }
            guard let chunk = UnixSocket.read(fd), !chunk.isEmpty else { throw ChromeError.disconnected }
            reader.append(chunk)
        }
    }

    func send(_ object: [String: Any]) throws {
        try UnixSocket.writeAll(fd, Frame.encode(try JSONSerialization.data(withJSONObject: object)))
    }
}

@Suite struct ChromeAdapterTests {
    static func socketPath() -> String { "/tmp/bb-\(UUID().uuidString.prefix(8)).sock" }

    static let treeJSON: [String: Any] = [
        "bar": ["id": "1", "title": "Bookmarks bar", "children": [
            ["id": "10", "title": "a", "url": "https://a.example"],
            ["id": "11", "title": "F", "children": [["id": "12", "title": "b", "url": "https://b.example"]]],
        ]],
        "other": ["id": "2", "title": "Other bookmarks", "children": []],
    ]

    /// Adapter listening on a fresh socket with a connected fake extension.
    static func rig(timeout: TimeInterval = 2) async throws -> (ChromeAdapter, FakeExtension) {
        let path = socketPath()
        let adapter = ChromeAdapter(socketURL: URL(fileURLWithPath: path), timeout: timeout)
        try adapter.start()
        let ext = try FakeExtension(path: path)
        for _ in 0..<100 where !adapter.isAvailable { try await Task.sleep(nanoseconds: 10_000_000) }
        return (adapter, ext)
    }

    @Test func framesRoundTripEvenWhenSplitAcrossReads() {
        let one = Frame.encode(Data("{\"a\":1}".utf8)), two = Frame.encode(Data("{}".utf8))
        let stream = one + two
        var reader = FrameReader()
        reader.append(stream.prefix(3))
        #expect(reader.next() == nil)
        reader.append(stream.dropFirst(3))
        #expect(reader.next() == Data("{\"a\":1}".utf8))
        #expect(reader.next() == Data("{}".utf8))
        #expect(reader.next() == nil)
        #expect(Array(one.prefix(4)) == [7, 0, 0, 0])
    }

    @Test func unavailableUntilTheExtensionConnects() async throws {
        let adapter = ChromeAdapter(socketURL: URL(fileURLWithPath: Self.socketPath()))
        try adapter.start()
        #expect(adapter.isAvailable == false)
        await #expect(throws: ChromeError.self) { _ = try await adapter.read() }
        adapter.stop()
    }

    @Test func readAsksForTheTreeAndMapsIt() async throws {
        let (adapter, ext) = try await Self.rig()
        async let tree = adapter.read()
        let request = try ext.receive()
        #expect(request["cmd"] as? String == "getTree")
        try ext.send(["id": request["id"]!, "ok": true, "tree": Self.treeJSON])
        let t = try await tree
        try t.validate()
        #expect(shape(t) == "bar:[a<https://a.example>,F[b<https://b.example>]] other:[]")
        #expect(t.root(.bar) == "1" && t.root(.other) == "2")
        adapter.stop()
    }

    @Test func applySendsOpsAndReturnsCreatedIDs() async throws {
        let (adapter, ext) = try await Self.rig()
        async let created = adapter.apply([
            .create(tempID: "t1", parent: "1", index: 0, title: "n", url: "https://n.example"),
            .create(tempID: "t2", parent: "t1", index: 0, title: "folder", url: nil),
            .update(id: "10", title: "A", url: "https://a.example"),
            .move(id: "12", parent: "2", index: 3),
            .remove(id: "11"),
        ])
        let request = try ext.receive()
        #expect(request["cmd"] as? String == "apply")
        let ops = request["ops"] as! [[String: Any]]
        #expect(ops.map { $0["op"] as! String } == ["create", "create", "update", "move", "remove"])
        #expect(ops[0]["tempId"] as? String == "t1" && ops[0]["parentId"] as? String == "1" && ops[0]["index"] as? Int == 0)
        #expect(ops[0]["url"] as? String == "https://n.example")
        #expect(ops[1]["url"] == nil)
        #expect(ops[3]["parentId"] as? String == "2" && ops[3]["index"] as? Int == 3)
        #expect(ops[4]["id"] as? String == "11")
        try ext.send(["id": request["id"]!, "ok": true, "created": ["t1": "99", "t2": "100"]])
        #expect(try await created == ["t1": "99", "t2": "100"])
        adapter.stop()
    }

    @Test func extensionErrorIsThrown() async throws {
        let (adapter, ext) = try await Self.rig()
        let task = Task { try await adapter.read() }
        let request = try ext.receive()
        try ext.send(["id": request["id"]!, "ok": false, "error": "boom"])
        await #expect(throws: ChromeError.extensionFailed("boom")) { _ = try await task.value }
        adapter.stop()
    }

    @Test func unansweredRequestTimesOut() async throws {
        let (adapter, ext) = try await Self.rig(timeout: 0.2)
        await #expect(throws: ChromeError.timedOut) { _ = try await adapter.read() }
        _ = ext
        adapter.stop()
    }

    @Test func connectionAndChangeEventsCallOnChange() async throws {
        let path = Self.socketPath()
        let adapter = ChromeAdapter(socketURL: URL(fileURLWithPath: path))
        let counter = Counter()
        adapter.onChange = { counter.bump() }
        try adapter.start()
        let ext = try FakeExtension(path: path)
        for _ in 0..<100 where counter.value < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(counter.value == 1)                    // connecting counts: there may be changes to catch up on
        try ext.send(["event": "changed"])
        for _ in 0..<100 where counter.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(counter.value == 2)
        adapter.stop()
    }

    @Test func disconnectMakesTheAdapterUnavailable() async throws {
        let path = Self.socketPath()
        let adapter = ChromeAdapter(socketURL: URL(fileURLWithPath: path))
        try adapter.start()
        do {
            _ = try FakeExtension(path: path)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(adapter.isAvailable == false)
        adapter.stop()
    }

    @Test func largeBatchesAreSentInChunksWithEarlierIDsResolved() async throws {
        let (adapter, ext) = try await Self.rig()
        var ops: [NativeOp] = [.create(tempID: "t0", parent: "1", index: 0, title: "Folder", url: nil)]
        for i in 1..<450 { ops.append(.create(tempID: "t\(i)", parent: "t0", index: i - 1, title: "b\(i)", url: "https://e.example/\(i)")) }
        let task = Task { try await adapter.apply(ops) }
        var sizes: [Int] = []
        var next = 900
        for _ in 0..<3 {
            let request = try ext.receive()
            let chunk = request["ops"] as! [[String: Any]]
            sizes.append(chunk.count)
            if sizes.count > 1 { #expect(chunk.allSatisfy { $0["parentId"] as? String == "900" }) }
            var created: [String: String] = [:]
            for op in chunk { created[op["tempId"] as! String] = String(next); next += 1 }
            try ext.send(["id": request["id"]!, "ok": true, "created": created])
        }
        let created = try await task.value
        #expect(sizes == [200, 200, 50])
        #expect(created.count == 450 && created["t0"] == "900" && created["t449"] == "1349")
        adapter.stop()
    }

    @Test func identityComesFromTheExtensionsProfileID() async throws {
        let (adapter, ext) = try await Self.rig()
        #expect(adapter.identity == nil)
        let task = Task { try await adapter.read() }
        let request = try ext.receive()
        var tree = Self.treeJSON
        tree["profile"] = "profile-abc"
        try ext.send(["id": request["id"]!, "ok": true, "tree": tree])
        _ = try await task.value
        #expect(adapter.identity == "profile-abc")
        adapter.stop()
    }
}
