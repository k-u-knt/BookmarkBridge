import Foundation

/// The operations that turn `current` into `target`. Both trees share an ID space
/// and root IDs; an ID that exists only in `target` becomes a `create` whose
/// `tempID` is that ID.
///
/// Order of the result:
/// 1. creates, parents before children;
/// 2. updates;
/// 3. moves to a new parent, outermost target folder first, so a folder is never
///    moved into its own descendant and nothing that survives is left inside a
///    folder about to be removed;
/// 4. removes, one per topmost removed node;
/// 5. moves that fix the order inside each folder.
public func diff(from current: Tree, to target: Tree) -> [NativeOp] {
    var ops: [NativeOp] = []
    var work = current                       // simulation of the browser as ops are applied
    let targetParents = target.parentMap()
    let targetOrder = target.contentIDs      // pre-order: parents before children

    func detach(_ id: String) {
        if let p = work.parent(of: id) { work.nodes[p]?.children.removeAll { $0 == id } }
    }

    // 1. Creates.
    for id in targetOrder where current.nodes[id] == nil {
        guard let node = target.nodes[id], let parent = targetParents[id] else { continue }
        let wanted = target.nodes[parent]?.children.firstIndex(of: id) ?? 0
        let index = min(wanted, work.nodes[parent]?.children.count ?? 0)
        ops.append(.create(tempID: id, parent: parent, index: index, title: node.title, url: node.url))
        work.nodes[id] = Node(id: id, title: node.title, url: node.url)
        work.nodes[parent]?.children.insert(id, at: index)
    }

    // 2. Updates.
    for id in targetOrder {
        guard let now = current.nodes[id], let want = target.nodes[id] else { continue }
        if now.title != want.title || now.url != want.url {
            ops.append(.update(id: id, title: want.title, url: want.url))
            work.nodes[id]?.title = want.title
            work.nodes[id]?.url = want.url
        }
    }

    // 3. Reparenting moves.
    for id in targetOrder {
        guard let parent = targetParents[id], work.parent(of: id) != parent else { continue }
        detach(id)
        let index = work.nodes[parent]?.children.count ?? 0
        ops.append(.move(id: id, parent: parent, index: index))
        work.nodes[parent]?.children.append(id)
    }

    // 4. Removes. Everything still under a removed node is itself being removed.
    for id in current.contentIDs where target.nodes[id] == nil && work.nodes[id] != nil {
        ops.append(.remove(id: id))
        let doomed = [id] + work.descendants(of: id)
        detach(id)
        for d in doomed { work.nodes[d] = nil }
    }

    // 5. Order inside each folder.
    let folders = RootKind.allCases.map { target.root($0) } + targetOrder.filter { target.nodes[$0]?.isFolder == true }
    for folder in folders {
        let want = target.nodes[folder]?.children ?? []
        for (i, id) in want.enumerated() where work.nodes[folder]?.children[safe: i] != id {
            work.nodes[folder]?.children.removeAll { $0 == id }
            work.nodes[folder]?.children.insert(id, at: i)
            ops.append(.move(id: id, parent: folder, index: i))
        }
    }
    return ops
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
