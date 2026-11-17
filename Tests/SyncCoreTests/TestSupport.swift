import Foundation
@testable import SyncCore

/// Builds trees tersely: `T.tree(bar: [.b("x"), .f("folder", [.b("y")])])`.
/// A spec's `id` defaults to its title, so tests can refer to nodes by name.
indirect enum Spec {
    case b(String, url: String? = nil, id: String? = nil)
    case f(String, [Spec], id: String? = nil)
}

enum T {
    static func tree(bar: [Spec] = [], other: [Spec] = []) -> Tree {
        var t = Tree.empty(barID: "bar", otherID: "other")
        for s in bar { add(s, to: "bar", in: &t) }
        for s in other { add(s, to: "other", in: &t) }
        return t
    }

    private static func add(_ s: Spec, to parent: String, in t: inout Tree) {
        switch s {
        case let .b(title, url, id):
            let nid = id ?? title
            t.nodes[nid] = Node(id: nid, title: title, url: url ?? "https://example.com/\(title)", children: [])
            t.nodes[parent]!.children.append(nid)
        case let .f(title, kids, id):
            let nid = id ?? title
            t.nodes[nid] = Node(id: nid, title: title, url: nil, children: [])
            t.nodes[parent]!.children.append(nid)
            for k in kids { add(k, to: nid, in: &t) }
        }
    }
}

/// Reference implementation of what a `NativeOp` means. Adapters must behave the same way.
func applyOps(_ ops: [NativeOp], to tree: Tree) -> Tree {
    var t = tree
    func detach(_ id: String) {
        if let p = t.parent(of: id) { t.nodes[p]!.children.removeAll { $0 == id } }
    }
    for op in ops {
        switch op {
        case let .create(tempID, parent, index, title, url):
            t.nodes[tempID] = Node(id: tempID, title: title, url: url)
            let i = min(index, t.nodes[parent]!.children.count)
            t.nodes[parent]!.children.insert(tempID, at: i)
        case let .update(id, title, url):
            t.nodes[id]!.title = title
            t.nodes[id]!.url = url
        case let .move(id, parent, index):
            detach(id)
            let i = min(index, t.nodes[parent]!.children.count)
            t.nodes[parent]!.children.insert(id, at: i)
        case let .remove(id):
            let doomed = [id] + t.descendants(of: id)
            detach(id)
            for d in doomed { t.nodes[d] = nil }
        }
    }
    return t
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum RandomTrees {
    static func make(count: Int, prefix: String, rng: inout SeededRNG) -> Tree {
        var t = Tree.empty(barID: "bar", otherID: "other")
        var folders = ["bar", "other"]
        for i in 0..<count {
            let id = "\(prefix)\(i)"
            let parent = folders.randomElement(using: &rng)!
            let isFolder = Int.random(in: 0..<4, using: &rng) == 0
            t.nodes[id] = Node(id: id, title: "t\(i)", url: isFolder ? nil : "https://e.com/\(i)")
            t.nodes[parent]!.children.append(id)
            if isFolder { folders.append(id) }
        }
        return t
    }

    /// Random adds, removals, renames, moves and reorders.
    static func mutate(_ tree: Tree, prefix: String, rng: inout SeededRNG) -> Tree {
        var t = tree
        for step in 0..<Int.random(in: 1...12, using: &rng) {
            let content = t.contentIDs
            let folders = [t.root(.bar), t.root(.other)] + content.filter { t.nodes[$0]!.isFolder }
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                let id = "\(prefix)\(step)"
                let parent = folders.randomElement(using: &rng)!
                let isFolder = Bool.random(using: &rng)
                t.nodes[id] = Node(id: id, title: id, url: isFolder ? nil : "https://n.com/\(id)")
                let n = t.nodes[parent]!.children.count
                t.nodes[parent]!.children.insert(id, at: Int.random(in: 0...n, using: &rng))
            case 1:
                guard let id = content.randomElement(using: &rng) else { continue }
                t = applyOps([.remove(id: id)], to: t)
            case 2:
                guard let id = content.randomElement(using: &rng) else { continue }
                t.nodes[id]!.title += "*"
            case 3:
                guard let id = content.randomElement(using: &rng) else { continue }
                let banned = Set([id] + t.descendants(of: id))
                guard let parent = folders.filter({ !banned.contains($0) }).randomElement(using: &rng) else { continue }
                let n = t.nodes[parent]!.children.filter { $0 != id }.count
                t = applyOps([.move(id: id, parent: parent, index: Int.random(in: 0...n, using: &rng))], to: t)
            default:
                let parent = folders.randomElement(using: &rng)!
                t.nodes[parent]!.children.shuffle(using: &rng)
            }
        }
        return t
    }
}
