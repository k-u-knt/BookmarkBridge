import Foundation

/// The two top-level folders every supported browser has in some form.
public enum RootKind: String, Codable, CaseIterable, Sendable {
    case bar    // Safari "Favorites" / Chrome "Bookmarks bar"
    case other  // Safari "Bookmarks Menu" + loose top-level items / Chrome "Other bookmarks"
}

public struct Node: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// `nil` means the node is a folder.
    public var url: String?
    /// Ordered child IDs. Always empty for bookmarks.
    public var children: [String]

    public var isFolder: Bool { url == nil }

    public init(id: String, title: String, url: String?, children: [String] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }
}

public enum TreeError: Error, Equatable {
    case missingRoot(RootKind)
    case missingNode(String)
    case multipleParents(String)
    case cycle(String)
    case orphan(String)
    case bookmarkWithChildren(String)
}

public struct Tree: Codable, Equatable, Sendable {
    public var nodes: [String: Node]
    /// Root folder ID per kind, keyed by `RootKind.rawValue`.
    public var rootIDs: [String: String]

    public init(nodes: [String: Node], roots: [RootKind: String]) {
        self.nodes = nodes
        self.rootIDs = Dictionary(uniqueKeysWithValues: roots.map { ($0.key.rawValue, $0.value) })
    }

    public static func empty(barID: String, otherID: String) -> Tree {
        Tree(
            nodes: [
                barID: Node(id: barID, title: "Bookmarks Bar", url: nil),
                otherID: Node(id: otherID, title: "Other Bookmarks", url: nil),
            ],
            roots: [.bar: barID, .other: otherID]
        )
    }

    public var roots: [RootKind: String] {
        var out: [RootKind: String] = [:]
        for (k, v) in rootIDs { if let kind = RootKind(rawValue: k) { out[kind] = v } }
        return out
    }

    public func root(_ kind: RootKind) -> String { rootIDs[kind.rawValue] ?? "" }

    public func isRoot(_ id: String) -> Bool { rootIDs.values.contains(id) }

    public func parent(of id: String) -> String? {
        parentMap()[id]
    }

    /// Child ID → parent ID for every non-root node reachable through `children`.
    public func parentMap() -> [String: String] {
        var map: [String: String] = [:]
        for node in nodes.values {
            for child in node.children { map[child] = node.id }
        }
        return map
    }

    /// Depth-first, pre-order, excluding `id` itself.
    public func descendants(of id: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = [id]
        func walk(_ nid: String) {
            for child in nodes[nid]?.children ?? [] where seen.insert(child).inserted {
                out.append(child)
                walk(child)
            }
        }
        walk(id)
        return out
    }

    /// IDs of every node under the roots, roots excluded.
    public var contentIDs: [String] {
        RootKind.allCases.flatMap { descendants(of: root($0)) }
    }

    public var bookmarkCount: Int {
        contentIDs.reduce(0) { $0 + ((nodes[$1]?.isFolder ?? true) ? 0 : 1) }
    }

    public func validate() throws {
        for kind in RootKind.allCases {
            guard let id = rootIDs[kind.rawValue], nodes[id] != nil else { throw TreeError.missingRoot(kind) }
        }
        var parentOf: [String: String] = [:]
        for node in nodes.values {
            if !node.isFolder && !node.children.isEmpty { throw TreeError.bookmarkWithChildren(node.id) }
            for child in node.children {
                guard nodes[child] != nil else { throw TreeError.missingNode(child) }
                if parentOf[child] != nil || isRoot(child) { throw TreeError.multipleParents(child) }
                parentOf[child] = node.id
            }
        }
        // Every non-root node must reach a root by walking up; anything else is a cycle or an orphan.
        for id in nodes.keys where !isRoot(id) {
            var cur = id
            var steps = 0
            while !isRoot(cur) {
                guard let p = parentOf[cur] else { throw TreeError.orphan(id) }
                cur = p
                steps += 1
                if steps > nodes.count { throw TreeError.cycle(id) }
            }
        }
    }
}
