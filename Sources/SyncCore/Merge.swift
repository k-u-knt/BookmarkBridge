import Foundation

public enum Side: String, Codable, Sendable {
    case a, b
    public var opposite: Side { self == .a ? .b : .a }
}

/// Three-way merge of two bookmark trees against their last common state.
///
/// All three trees use the same ID space and the same root IDs. `prefer` names the
/// side that wins when both changed the same thing differently.
///
/// Rules:
/// - Something added on either side is kept.
/// - Something removed on one side is removed, unless the other side changed it
///   or put something inside it (an edit beats a delete).
/// - Title, URL and parent each come from whichever side changed them.
/// - A folder's order comes from whichever side reordered it; items the other
///   side added are slotted in after their nearest surviving left neighbour.
public func merge(base: Tree, a: Tree, b: Tree, prefer: Side) -> Tree {
    let trees: [Side: Tree] = [.a: a, .b: b]
    let parents: [Side: [String: String]] = [.a: a.parentMap(), .b: b.parentMap()]
    let baseParents = base.parentMap()

    func has(_ side: Side, _ id: String) -> Bool { trees[side]!.nodes[id] != nil && !base.isRoot(id) }

    /// Picks a field's merged value for a node present on at least one side.
    func pick<V: Equatable>(_ id: String, _ value: (Side) -> V?, base baseValue: V?) -> V? {
        let inA = has(.a, id), inB = has(.b, id)
        if inA != inB { return value(inA ? .a : .b) }
        let va = value(.a), vb = value(.b)
        if va == vb { return va }
        let aChanged = va != baseValue, bChanged = vb != baseValue
        if aChanged && !bChanged { return va }
        if bChanged && !aChanged { return vb }
        return value(prefer)
    }

    func unchanged(_ side: Side, _ id: String) -> Bool {
        guard let n = trees[side]!.nodes[id], let bn = base.nodes[id] else { return false }
        return n.title == bn.title && n.url == bn.url && parents[side]![id] == baseParents[id]
    }

    // 1. Which nodes survive.
    var survivors = Set<String>()
    let allIDs = Set(a.contentIDs).union(b.contentIDs)
    for id in allIDs {
        let inA = has(.a, id), inB = has(.b, id)
        if inA && inB { survivors.insert(id); continue }
        let present: Side = inA ? .a : .b
        if base.nodes[id] == nil || base.isRoot(id) {
            survivors.insert(id)                       // added on one side
        } else if !unchanged(present, id) {
            survivors.insert(id)                       // edited on one side, deleted on the other
        }
    }

    // 2. Parents, resurrecting any deleted folder that still has to hold a survivor.
    var parentOf: [String: String] = [:]
    func chooseParent(_ id: String) -> String {
        pick(id, { parents[$0]![id] }, base: baseParents[id]) ?? base.root(.other)
    }
    var queue = Array(survivors)
    while let id = queue.popLast() {
        let p = chooseParent(id)
        parentOf[id] = p
        if !base.isRoot(p) && survivors.insert(p).inserted { queue.append(p) }
    }

    // 3. Break cycles that opposing moves can create: fall back to the preferred
    //    side's parent, then to the base parent.
    func cycleMembers() -> [String]? {
        for start in survivors {
            var seen: [String] = []
            var cur = start
            while !base.isRoot(cur) {
                if let i = seen.firstIndex(of: cur) { return Array(seen[i...]) }
                seen.append(cur)
                guard let p = parentOf[cur] else { break }
                cur = p
            }
        }
        return nil
    }
    for fallback in [parents[prefer]!, baseParents] {
        guard let members = cycleMembers() else { break }
        for id in members {
            if let p = fallback[id], base.isRoot(p) || survivors.contains(p) { parentOf[id] = p }
        }
    }
    if let members = cycleMembers() {
        // Cannot happen with valid inputs; keep the tree valid regardless.
        for id in members { parentOf[id] = base.root(.other) }
    }

    // 4. Build nodes.
    var result = Tree(nodes: [:], roots: base.roots)
    for kind in RootKind.allCases {
        let rid = base.root(kind)
        result.nodes[rid] = Node(id: rid, title: base.nodes[rid]?.title ?? "", url: nil)
    }
    for id in survivors {
        let title = pick(id, { trees[$0]!.nodes[id]?.title }, base: base.nodes[id]?.title) ?? ""
        // A node's kind never changes, so only bookmarks merge their URL.
        let anyNode = a.nodes[id] ?? b.nodes[id]
        let url: String? = anyNode?.isFolder == true
            ? nil
            : pick(id, { trees[$0]!.nodes[id]?.url }, base: base.nodes[id]?.url)
        result.nodes[id] = Node(id: id, title: title, url: url)
    }

    // 5. Child order per folder.
    var members: [String: Set<String>] = [:]
    for (child, parent) in parentOf { members[parent, default: []].insert(child) }

    for (folder, set) in members {
        func list(_ side: Side) -> [String]? { trees[side]!.nodes[folder]?.children }
        let baseList = base.nodes[folder]?.children
        let primary: Side
        switch (list(.a), list(.b)) {
        case (nil, _): primary = .b
        case (_, nil): primary = .a
        case let (la?, lb?):
            // "Reordered" compares only the items the side shares with base, so a
            // plain addition or removal does not count as a reorder.
            func reordered(_ l: [String]) -> Bool {
                guard let bl = baseList else { return false }
                let common = Set(l).intersection(bl)
                return l.filter(common.contains) != bl.filter(common.contains)
            }
            let aChanged = reordered(la), bChanged = reordered(lb)
            primary = (aChanged && !bChanged) ? .a : (bChanged && !aChanged) ? .b : prefer
        }
        var order = (list(primary) ?? []).filter { set.contains($0) }
        var placed = Set(order)
        let secondary = list(primary.opposite) ?? []
        for (i, id) in secondary.enumerated() where set.contains(id) && !placed.contains(id) {
            // After the nearest left neighbour that made it into the result, else at the front.
            var insertAt = 0
            for left in secondary[..<i].reversed() {
                if let pos = order.firstIndex(of: left) { insertAt = pos + 1; break }
            }
            order.insert(id, at: insertAt)
            placed.insert(id)
        }
        // Anything whose parent came from a fallback and is in neither list.
        order.append(contentsOf: set.subtracting(placed).sorted())
        result.nodes[folder]?.children = order
    }
    return result
}
