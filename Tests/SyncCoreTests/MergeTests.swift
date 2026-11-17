import Testing
@testable import SyncCore

@Suite struct MergeTests {
    func kids(_ t: Tree, _ id: String) -> [String] { t.nodes[id]!.children }

    @Test func unchangedSidesGiveBase() throws {
        let base = T.tree(bar: [.b("x"), .f("F", [.b("y")])])
        #expect(merge(base: base, a: base, b: base, prefer: .a) == base)
    }

    @Test func additionOnOneSideIsKept() throws {
        let base = T.tree(bar: [.b("x")])
        let a = T.tree(bar: [.b("x"), .b("n")])
        let m = merge(base: base, a: a, b: base, prefer: .b)
        #expect(kids(m, "bar") == ["x", "n"])
        try m.validate()
    }

    @Test func deletionOnOneSideIsApplied() throws {
        let base = T.tree(bar: [.b("x"), .b("y")])
        let a = T.tree(bar: [.b("x")])
        let m = merge(base: base, a: a, b: base, prefer: .b)
        #expect(kids(m, "bar") == ["x"])
        #expect(m.nodes["y"] == nil)
    }

    @Test func deletionOnBothSidesIsApplied() throws {
        let base = T.tree(bar: [.b("x"), .b("y")])
        let side = T.tree(bar: [.b("x")])
        #expect(merge(base: base, a: side, b: side, prefer: .a) == side)
    }

    @Test func editBeatsDelete() throws {
        let base = T.tree(bar: [.b("x")])
        let a = T.tree()
        var b = base
        b.nodes["x"]!.title = "renamed"
        let m = merge(base: base, a: a, b: b, prefer: .a)
        #expect(m.nodes["x"]?.title == "renamed")
        #expect(kids(m, "bar") == ["x"])
    }

    @Test func sameFieldConflictFollowsPreferredSide() throws {
        let base = T.tree(bar: [.b("x")])
        var a = base, b = base
        a.nodes["x"]!.title = "A"
        b.nodes["x"]!.title = "B"
        #expect(merge(base: base, a: a, b: b, prefer: .a).nodes["x"]!.title == "A")
        #expect(merge(base: base, a: a, b: b, prefer: .b).nodes["x"]!.title == "B")
    }

    @Test func moveOnOneSideAndRenameOnTheOtherBothApply() throws {
        let base = T.tree(bar: [.b("x")])
        let a = T.tree(other: [.b("x")])
        var b = base
        b.nodes["x"]!.title = "renamed"
        let m = merge(base: base, a: a, b: b, prefer: .b)
        #expect(kids(m, "other") == ["x"])
        #expect(kids(m, "bar") == [])
        #expect(m.nodes["x"]!.title == "renamed")
        try m.validate()
    }

    @Test func reorderOnOneSideKeepsAdditionFromTheOther() throws {
        let base = T.tree(bar: [.b("x"), .b("y"), .b("z")])
        let a = T.tree(bar: [.b("z"), .b("y"), .b("x")])
        let b = T.tree(bar: [.b("x"), .b("n"), .b("y"), .b("z")])
        let m = merge(base: base, a: a, b: b, prefer: .b)
        #expect(kids(m, "bar") == ["z", "y", "x", "n"])
    }

    @Test func folderDeletedOnOneSideSurvivesWhenOtherSideAddedInsideIt() throws {
        let base = T.tree(bar: [.f("F", [.b("c")])])
        let a = T.tree()
        let b = T.tree(bar: [.f("F", [.b("c"), .b("n")])])
        let m = merge(base: base, a: a, b: b, prefer: .a)
        #expect(kids(m, "bar") == ["F"])
        #expect(kids(m, "F") == ["n"])
        try m.validate()
    }

    @Test func folderDeletedOnOneSideSurvivesWhenOtherSideMovedSomethingIn() throws {
        let base = T.tree(bar: [.f("F", []), .b("x")])
        let a = T.tree(bar: [.b("x")])
        let b = T.tree(bar: [.f("F", [.b("x")])])
        let m = merge(base: base, a: a, b: b, prefer: .a)
        #expect(kids(m, "F") == ["x"])
        try m.validate()
    }

    @Test func identicalTwinsBothSurvive() throws {
        let base = T.tree()
        let a = T.tree(bar: [.b("t", url: "https://t", id: "t1"), .b("t", url: "https://t", id: "t2")])
        let m = merge(base: base, a: a, b: base, prefer: .b)
        #expect(kids(m, "bar") == ["t1", "t2"])
    }

    @Test func opposingMovesDoNotCreateACycle() throws {
        let base = T.tree(bar: [.f("F", []), .f("G", [])])
        let a = T.tree(bar: [.f("G", [.f("F", [])])])
        let b = T.tree(bar: [.f("F", [.f("G", [])])])
        let m = merge(base: base, a: a, b: b, prefer: .a)
        try m.validate()
        #expect(kids(m, "G") == ["F"])
        #expect(kids(m, "bar") == ["G"])
    }

    @Test func additionsOnBothSidesAreBothKept() throws {
        let base = T.tree(bar: [.b("x")])
        let a = T.tree(bar: [.b("x"), .b("na")])
        let b = T.tree(bar: [.b("nb"), .b("x")])
        let m = merge(base: base, a: a, b: b, prefer: .a)
        #expect(Set(kids(m, "bar")) == ["x", "na", "nb"])
        try m.validate()
    }
}
