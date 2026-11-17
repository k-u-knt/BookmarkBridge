import Testing
@testable import SyncCore

@Suite struct BookmarkTreeTests {
    @Test func validTreePassesValidation() throws {
        try T.tree(bar: [.b("a"), .f("F", [.b("b")])]).validate()
    }

    @Test func validateRejectsMissingChild() {
        var t = T.tree(bar: [.b("a")])
        t.nodes["bar"]!.children.append("ghost")
        #expect(throws: TreeError.self) { try t.validate() }
    }

    @Test func validateRejectsNodeWithTwoParents() {
        var t = T.tree(bar: [.b("a")], other: [.f("F", [])])
        t.nodes["F"]!.children.append("a")
        #expect(throws: TreeError.self) { try t.validate() }
    }

    @Test func validateRejectsCycle() {
        var t = T.tree(bar: [.f("F", [.f("G", [])])])
        t.nodes["bar"]!.children = []
        t.nodes["G"]!.children = ["F"]
        #expect(throws: TreeError.self) { try t.validate() }
    }

    @Test func bookmarkCountIgnoresFolders() {
        #expect(T.tree(bar: [.b("a"), .f("F", [.b("b"), .f("G", [])])]).bookmarkCount == 2)
    }

    @Test func descendantsAreDepthFirst() {
        let t = T.tree(bar: [.f("F", [.b("a"), .f("G", [.b("b")])]), .b("c")])
        #expect(t.descendants(of: "bar") == ["F", "a", "G", "b", "c"])
    }

    @Test func parentLookup() {
        let t = T.tree(bar: [.f("F", [.b("a")])])
        #expect(t.parent(of: "a") == "F")
        #expect(t.parent(of: "bar") == nil)
    }
}
