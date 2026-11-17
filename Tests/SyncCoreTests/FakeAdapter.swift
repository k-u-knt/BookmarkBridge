import Foundation
@testable import SyncCore

/// In-memory browser. Assigns its own IDs on create, like a real one.
final class FakeAdapter: BrowserAdapter {
    let name: String
    var isAvailable = true
    var tree: Tree
    var onChange: (() -> Void)?
    var readError: Error?
    /// When true, `apply` reports success but changes nothing (a browser that reverts outside edits).
    var ignoresWrites = false
    /// Like Chrome: stores "https://host" as "https://host/".
    var normalizesURLs = false
    /// Throws after applying this many ops, without reporting what it created (a dropped connection).
    var failAfterOps: Int?
    var identity: String?
    var backupFiles: [URL] = []
    struct Dropped: Error {}
    private var counter = 0

    init(name: String, tree: Tree? = nil) {
        self.name = name
        self.tree = tree ?? Tree.empty(barID: "\(name)-bar", otherID: "\(name)-other")
    }

    func read() async throws -> Tree {
        if let readError { throw readError }
        return tree
    }

    func apply(_ ops: [NativeOp]) async throws -> [String: String] {
        var created: [String: String] = [:]
        if ignoresWrites {
            for case let .create(tempID, _, _, _, _) in ops { created[tempID] = "ghost-\(tempID)" }
            return created
        }
        func real(_ id: String) -> String { created[id] ?? id }
        func norm(_ url: String?) -> String? {
            guard normalizesURLs, let url, url.split(separator: "/").count == 2 else { return url }
            return url + "/"
        }
        for (n, op) in ops.enumerated() {
            if let limit = failAfterOps, n >= limit { failAfterOps = nil; throw Dropped() }
            switch op {
            case let .create(tempID, parent, index, title, rawURL):
                let url = norm(rawURL)
                counter += 1
                let nid = "\(name)-\(counter)"
                created[tempID] = nid
                tree = applyOps([.create(tempID: nid, parent: real(parent), index: index, title: title, url: url)], to: tree)
            case let .update(id, title, url):
                tree = applyOps([.update(id: real(id), title: title, url: norm(url))], to: tree)
            case let .move(id, parent, index):
                tree = applyOps([.move(id: real(id), parent: real(parent), index: index)], to: tree)
            case let .remove(id):
                tree = applyOps([.remove(id: real(id))], to: tree)
            }
        }
        return created
    }

    // Test conveniences, acting as the user would in the browser.
    var bar: String { tree.root(.bar) }
    @discardableResult
    func add(_ title: String, to parent: String? = nil, folder: Bool = false) -> String {
        counter += 1
        let id = "\(name)-u\(counter)"
        tree.nodes[id] = Node(id: id, title: title, url: folder ? nil : "https://example.com/\(title)")
        tree.nodes[parent ?? bar]!.children.append(id)
        return id
    }
    func id(_ title: String) -> String { tree.nodes.values.first { $0.title == title }!.id }
    func remove(_ title: String) { tree = applyOps([.remove(id: id(title))], to: tree) }
    func rename(_ title: String, to new: String) { tree.nodes[id(title)]!.title = new }
}

/// Titles and URLs only, so trees from different browsers can be compared.
func shape(_ tree: Tree) -> String {
    func walk(_ id: String) -> String {
        let n = tree.nodes[id]!
        return n.isFolder ? "\(n.title)[\(n.children.map(walk).joined(separator: ","))]" : "\(n.title)<\(n.url!)>"
    }
    return RootKind.allCases.map { kind in
        "\(kind.rawValue):[\(tree.nodes[tree.root(kind)]!.children.map(walk).joined(separator: ","))]"
    }.joined(separator: " ")
}
