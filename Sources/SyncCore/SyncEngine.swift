import Foundation

public enum SyncOutcome: Equatable, Sendable {
    case noChanges
    case synced(summary: [String])
    /// Nothing was changed; syncing would remove this many bookmarks from the named browser.
    case needsConfirmation(removals: Int, on: String)
    /// Nothing was changed; the named browser cannot be reached.
    case unavailable(String)
}

public enum SyncError: Error, Equatable, LocalizedError {
    case notSetUp
    case emptySource(String)
    case suspiciousEmptyTree(String)
    case writeNotReflected(String)
    case backupMissing(String)
    case rootsChanged(String)
    case differentProfile(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: return "Sync has not been set up yet."
        case let .emptySource(name): return "\(name) has no bookmarks to copy."
        case let .suspiciousEmptyTree(name):
            return "\(name) reported no bookmarks at all. Nothing was changed, in case that is a reading problem."
        case let .writeNotReflected(name):
            return "\(name) did not keep the changes that were written to it. Nothing was removed anywhere."
        case let .backupMissing(name): return "The backup has no bookmarks saved for \(name)."
        case let .rootsChanged(name):
            return "\(name)'s main bookmark folders are not the ones sync was set up with (this happens when signing in or out of the browser). Nothing was changed. Use Reset Sync to set up again."
        case let .differentProfile(name):
            return "\(name) is connected with a different profile than the one sync was set up with. Nothing was changed."
        }
    }
}

/// Keeps two browsers' bookmarks identical. Not thread-safe: call from one task at a time.
public final class SyncEngine {
    public static let canonicalBar = "root-bar"
    public static let canonicalOther = "root-other"

    private let adapters: [Side: BrowserAdapter]
    private let store: StateStore
    private let sides: [Side] = [.a, .b]

    public init(a: BrowserAdapter, b: BrowserAdapter, store: StateStore) {
        self.adapters = [.a: a, .b: b]
        self.store = store
    }

    public var isSetUp: Bool { ((try? store.load()) ?? nil) != nil }

    // MARK: Setup

    /// Backs up both browsers, then replaces the other browser's bookmarks with `source`'s.
    public func setUp(source: Side) async throws {
        let dest = source.opposite
        let src = adapters[source]!, dst = adapters[dest]!
        let srcNative = try await readValidated(src)
        let dstNative = try await readValidated(dst)
        guard srcNative.bookmarkCount > 0 else { throw SyncError.emptySource(src.name) }
        try backup([source: srcNative, dest: dstNative], keepForever: true)

        var srcMap: [String: String] = [:], dstMap: [String: String] = [:]
        let base = canonical(srcNative, map: &srcMap, pending: [:])
        let dstCanon = canonical(dstNative, map: &dstMap, pending: [:])
        let ops = diff(from: dstCanon, to: base)

        // Saved before writing: if the write is cut off, the next sync recognises what
        // was already created and finishes the copy instead of duplicating it.
        var state = SyncState(base: base, idMaps: [src.name: srcMap, dst.name: dstMap], activity: [])
        state.pendingCreates = [dst.name: pendingCreates(in: ops)]
        state.rootIDs = [src.name: srcNative.rootIDs, dst.name: dstNative.rootIDs]
        state.identities = identities()
        state.activity = [ActivityEntry(summary: "Set up: copied \(base.bookmarkCount) bookmarks · \(src.name) → \(dst.name)")]
        try store.save(state)

        let created = try await dst.apply(native(ops, map: dstMap, tree: dstNative))
        state.idMaps[dst.name] = rebuiltMap(for: base, old: dstMap, created: created)
        state.pendingCreates = nil
        try store.save(state)

        var verifyMap = state.idMaps[dst.name]!
        let readBack = canonical(try await readValidated(dst), map: &verifyMap, pending: [:])
        guard sameStructure(readBack, base) else { throw SyncError.writeNotReflected(dst.name) }
        if readBack != base {
            // The destination stored a title or URL in its own form; let that flow back.
            _ = try await syncOnce(prefer: dest, confirmedRemovals: nil)
        }
    }

    // MARK: Sync

    /// One round of two-way sync. `prefer` is the side whose change was seen most recently.
    /// `confirmedRemovals` is the number of removals the person has already agreed to.
    public func sync(prefer: Side, confirmedRemovals: Int? = nil) async throws -> SyncOutcome {
        let (outcome, drifted) = try await syncOnce(prefer: prefer, confirmedRemovals: confirmedRemovals)
        if let drifted {
            // A browser stored something in its own form (Chrome rewrites some URLs).
            // One more round carries that form to the other browser.
            _ = try await syncOnce(prefer: drifted, confirmedRemovals: nil)
        }
        return outcome
    }

    /// Returns the outcome and, if a browser stored a title or URL differently from what was written, which one.
    private func syncOnce(prefer: Side, confirmedRemovals: Int?) async throws -> (SyncOutcome, drifted: Side?) {
        guard var state = try store.load() else { throw SyncError.notSetUp }
        for side in sides where !adapters[side]!.isAvailable {
            return (.unavailable(adapters[side]!.name), nil)
        }

        var natives: [Side: Tree] = [:], canon: [Side: Tree] = [:], maps: [Side: [String: String]] = [:]
        for side in sides {
            let adapter = adapters[side]!
            let tree = try await readValidated(adapter)
            if let expected = state.identities?[adapter.name], let actual = adapter.identity, expected != actual {
                throw SyncError.differentProfile(adapter.name)
            }
            if let expected = state.rootIDs?[adapter.name], expected != tree.rootIDs {
                throw SyncError.rootsChanged(adapter.name)
            }
            if tree.bookmarkCount == 0 && state.base.bookmarkCount > 0 {
                throw SyncError.suspiciousEmptyTree(adapter.name)
            }
            var map = state.idMaps[adapter.name] ?? [:]
            canon[side] = canonical(tree, map: &map, pending: state.pendingCreates?[adapter.name] ?? [:])
            natives[side] = tree
            maps[side] = map
        }

        let merged = merge(base: state.base, a: canon[.a]!, b: canon[.b]!, prefer: prefer)
        let ops: [Side: [NativeOp]] = [
            .a: diff(from: canon[.a]!, to: merged),
            .b: diff(from: canon[.b]!, to: merged),
        ]

        func finish(_ summary: [String]) throws {
            state.base = merged
            for side in sides {
                state.idMaps[adapters[side]!.name] = rebuiltMap(for: merged, old: maps[side]!, created: [:])
            }
            state.pendingCreates = nil
            if state.rootIDs == nil {
                state.rootIDs = Dictionary(uniqueKeysWithValues: sides.map { (adapters[$0]!.name, natives[$0]!.rootIDs) })
            }
            if state.identities == nil { state.identities = identities() }
            let now = Date()
            state.activity.insert(contentsOf: summary.map { ActivityEntry(date: now, summary: $0) }, at: 0)
            try store.save(state)
        }

        if ops[.a]!.isEmpty && ops[.b]!.isEmpty {
            // Either nothing happened, or both sides already agree (same change made in
            // both, or an interrupted write that had in fact completed).
            if merged != state.base || state.pendingCreates != nil { try finish([]) }
            return (.noChanges, nil)
        }

        for side in sides {
            let tree = canon[side]!
            let removals = tree.contentIDs.filter { tree.nodes[$0]?.isFolder == false && merged.nodes[$0] == nil }.count
            let threshold = max(25, tree.bookmarkCount / 5, confirmedRemovals ?? 0)
            if removals > threshold { return (.needsConfirmation(removals: removals, on: adapters[side]!.name), nil) }
        }

        try backup(natives, keepForever: false)

        // Before writing anything, remember the IDs given to newly seen bookmarks and
        // what each browser is about to be asked to create. If a write is cut off,
        // the next round recognises its results instead of taking them for new bookmarks.
        var pending: [String: [String: PendingCreate]] = [:]
        for side in sides {
            state.idMaps[adapters[side]!.name] = maps[side]!
            pending[adapters[side]!.name] = pendingCreates(in: ops[side]!)
        }
        state.pendingCreates = pending
        try store.save(state)

        var summary: [String] = []
        var drifted: Side?
        for side in sides where !ops[side]!.isEmpty {
            let adapter = adapters[side]!
            let created = try await adapter.apply(native(ops[side]!, map: maps[side]!, tree: natives[side]!))
            maps[side] = rebuiltMap(for: merged, old: maps[side]!, created: created)
            state.idMaps[adapter.name] = maps[side]!
            state.pendingCreates?[adapter.name] = nil
            try store.save(state)

            var verifyMap = maps[side]!
            let readBack = canonical(try await readValidated(adapter), map: &verifyMap, pending: [:])
            guard sameStructure(readBack, merged) else { throw SyncError.writeNotReflected(adapter.name) }
            if readBack != merged { drifted = side }
            summary += describe(ops[side]!, before: canon[side]!,
                                from: adapters[side.opposite]!.name, to: adapter.name)
        }

        try finish(summary)
        return (.synced(summary: summary), drifted)
    }

    // MARK: Restore

    /// Puts each browser back to its own bookmarks from `backup`. The sync state is
    /// forgotten first, because the two browsers may no longer match and a half-finished
    /// restore must never be followed by an automatic sync. Setup must be run again.
    public func restore(backup folder: URL) async throws {
        let saved = try store.readBackup(folder)
        var current: [Side: Tree] = [:]
        var targets: [Side: Tree] = [:]
        for side in sides {
            let adapter = adapters[side]!
            guard var target = saved[adapter.name] else { throw SyncError.backupMissing(adapter.name) }
            let now = try await readValidated(adapter)
            // Root IDs are stable in practice; re-key them if a browser changed one.
            for kind in RootKind.allCases where target.root(kind) != now.root(kind) {
                let old = target.root(kind), new = now.root(kind)
                guard var node = target.nodes.removeValue(forKey: old) else { throw SyncError.backupMissing(adapter.name) }
                node.id = new
                target.nodes[new] = node
                target.rootIDs[kind.rawValue] = new
            }
            try target.validate()
            current[side] = now
            targets[side] = target
        }
        try backup(current, keepForever: false)
        try store.reset()
        for side in sides {
            // Nodes that still exist keep their ID; the rest are created again.
            _ = try await adapters[side]!.apply(diff(from: current[side]!, to: targets[side]!))
        }
    }

    // MARK: Helpers

    private func readValidated(_ adapter: BrowserAdapter) async throws -> Tree {
        let tree = try await adapter.read()
        try tree.validate()
        return tree
    }

    private func identities() -> [String: String] {
        var out: [String: String] = [:]
        for side in sides { if let id = adapters[side]!.identity { out[adapters[side]!.name] = id } }
        return out
    }

    /// Backs up both trees, unless the newest backup already holds exactly these trees
    /// (a failing sync that retries must not push older backups out).
    private func backup(_ natives: [Side: Tree], keepForever: Bool) throws {
        var trees: [String: Tree] = [:]
        var files: [URL] = []
        for (side, tree) in natives {
            trees[adapters[side]!.name] = tree
            files += adapters[side]!.backupFiles
        }
        if !keepForever, let newest = store.listBackups().first, (try? store.readBackup(newest)) == trees { return }
        try store.writeBackup(trees: trees, extraFiles: files, keepForever: keepForever)
    }

    private func sameStructure(_ x: Tree, _ y: Tree) -> Bool {
        guard x.nodes.count == y.nodes.count else { return false }
        for (id, node) in x.nodes {
            guard let other = y.nodes[id], other.children == node.children, other.isFolder == node.isFolder else { return false }
        }
        return true
    }

    private func pendingCreates(in ops: [NativeOp]) -> [String: PendingCreate] {
        var out: [String: PendingCreate] = [:]
        for case let .create(tempID, parent, _, title, url) in ops {
            out[tempID] = PendingCreate(parent: parent, title: title, url: url)
        }
        return out
    }

    /// Rewrites a browser's tree in canonical IDs. `map` is canonical → native. A native ID
    /// not in it is first matched against `pending` (something this app asked the browser
    /// to create, by folder, title and URL); failing that it gets a new canonical ID.
    private func canonical(_ tree: Tree, map: inout [String: String], pending: [String: PendingCreate]) -> Tree {
        var toCanon: [String: String] = [
            tree.root(.bar): Self.canonicalBar,
            tree.root(.other): Self.canonicalOther,
        ]
        for (canon, native) in map where tree.nodes[native] != nil { toCanon[native] = canon }
        var claimed = Set(toCanon.values)
        var unclaimed = pending.filter { !claimed.contains($0.key) }
        let parents = tree.parentMap()

        for id in tree.contentIDs where toCanon[id] == nil {     // pre-order: a parent is resolved before its children
            guard let node = tree.nodes[id] else { continue }
            let parentCanon = parents[id].flatMap { toCanon[$0] }
            let match = unclaimed.filter { $0.value.parent == parentCanon && $0.value.title == node.title && $0.value.url == node.url }
                .keys.sorted().first
            let canon = match ?? UUID().uuidString
            if let match { unclaimed[match] = nil }
            claimed.insert(canon)
            toCanon[id] = canon
            map[canon] = id
        }

        var out = Tree.empty(barID: Self.canonicalBar, otherID: Self.canonicalOther)
        for id in [tree.root(.bar), tree.root(.other)] + tree.contentIDs {
            guard let node = tree.nodes[id], let cid = toCanon[id] else { continue }
            let title = tree.isRoot(id) ? out.nodes[cid]!.title : node.title
            out.nodes[cid] = Node(id: cid, title: title, url: node.url, children: node.children.compactMap { toCanon[$0] })
        }
        return out
    }

    /// Rewrites canonical-ID ops in a browser's native IDs. IDs created in the same batch stay as temp IDs.
    private func native(_ ops: [NativeOp], map: [String: String], tree: Tree) -> [NativeOp] {
        func n(_ id: String) -> String {
            switch id {
            case Self.canonicalBar: return tree.root(.bar)
            case Self.canonicalOther: return tree.root(.other)
            default: return map[id] ?? id
            }
        }
        return ops.map { op in
            switch op {
            case let .create(tempID, parent, index, title, url):
                return .create(tempID: tempID, parent: n(parent), index: index, title: title, url: url)
            case let .update(id, title, url): return .update(id: n(id), title: title, url: url)
            case let .move(id, parent, index): return .move(id: n(id), parent: n(parent), index: index)
            case let .remove(id): return .remove(id: n(id))
            }
        }
    }

    /// The map for exactly the nodes in `tree`: known native IDs plus the ones just created.
    private func rebuiltMap(for tree: Tree, old: [String: String], created: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for id in tree.contentIDs {
            if let native = created[id] ?? old[id] { out[id] = native }
        }
        return out
    }

    private func describe(_ ops: [NativeOp], before: Tree, from: String, to: String) -> [String] {
        var added: [String] = [], edited: [String] = [], removed: [String] = []
        var moved = 0
        for op in ops {
            switch op {
            case let .create(_, _, _, title, _): added.append(title)
            case let .update(_, title, _): edited.append(title)
            case let .remove(id): removed.append(before.nodes[id]?.title ?? "item")
            case .move: moved += 1
            }
        }
        let arrow = " · \(from) → \(to)"
        func lines(_ verb: String, _ titles: [String]) -> [String] {
            if titles.count > 3 { return ["\(verb) \(titles.count) items\(arrow)"] }
            return titles.map { "\(verb) “\($0)”\(arrow)" }
        }
        var out = lines("Added", added) + lines("Edited", edited) + lines("Removed", removed)
        if moved > 0 { out.append("Moved \(moved) item\(moved == 1 ? "" : "s")\(arrow)") }
        return out
    }
}
