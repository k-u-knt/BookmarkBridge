import Testing
@testable import SyncCore

@Suite struct DiffTests {
    @Test func identicalTreesNeedNoOps() {
        let t = T.tree(bar: [.b("x"), .f("F", [.b("y")])])
        #expect(diff(from: t, to: t).isEmpty)
    }

    @Test func singleAdditionIsOneCreate() {
        let from = T.tree(bar: [.b("x")])
        let to = T.tree(bar: [.b("n"), .b("x")])
        #expect(diff(from: from, to: to) == [.create(tempID: "n", parent: "bar", index: 0, title: "n", url: "https://example.com/n")])
    }

    @Test func removingAFolderIsOneRemove() {
        let from = T.tree(bar: [.f("F", [.b("a"), .b("b")]), .b("x")])
        let to = T.tree(bar: [.b("x")])
        #expect(diff(from: from, to: to) == [.remove(id: "F")])
    }

    @Test func childIsRescuedBeforeItsFolderIsRemoved() throws {
        let from = T.tree(bar: [.f("F", [.b("keep"), .b("drop")])])
        let to = T.tree(bar: [.b("keep")])
        let ops = diff(from: from, to: to)
        #expect(applyOps(ops, to: from) == to)
    }

    @Test func swappedNestingNeverMovesAFolderIntoItsOwnDescendant() throws {
        let from = T.tree(bar: [.f("X", [.f("P", [])])])
        let to = T.tree(bar: [.f("P", [.f("X", [])])])
        var t = from
        for op in diff(from: from, to: to) {
            if case let .move(id, parent, _) = op {
                #expect(!([id] + t.descendants(of: id)).contains(parent))
            }
            t = applyOps([op], to: t)
        }
        #expect(t == to)
    }

    @Test func randomTreePairsRoundTrip() throws {
        var rng = SeededRNG(seed: 42)
        for i in 0..<200 {
            let from = RandomTrees.make(count: Int.random(in: 0...30, using: &rng), prefix: "n", rng: &rng)
            let to = RandomTrees.mutate(from, prefix: "m\(i)_", rng: &rng)
            let result = applyOps(diff(from: from, to: to), to: from)
            #expect(result == to, "pair \(i)")
            try result.validate()
        }
    }
}
