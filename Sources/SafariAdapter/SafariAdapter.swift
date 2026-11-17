import Foundation
import SyncCore

public enum SafariError: Error, LocalizedError {
    case unreadable(String)
    case malformed
    case unknownID(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(why): return "Safari's bookmarks file could not be read (\(why)). Full Disk Access may be missing."
        case .malformed: return "Safari's bookmarks file is not in the expected format."
        case let .unknownID(id): return "Safari has no bookmark with ID \(id)."
        }
    }
}

/// Safari's bookmarks, through `~/Library/Safari/Bookmarks.plist`.
///
/// Mapping: the top-level `BookmarksBar` folder is the `.bar` root. The `.other` root
/// does not exist in the file: its children are the children of `BookmarksMenu`
/// followed by every other top-level folder or bookmark. Reading List and the
/// History proxy are left alone. Writes edit the parsed file in place, so keys
/// this code does not understand are preserved.
public final class SafariAdapter: BrowserAdapter {
    public static let otherRootID = "safari-other"
    public static let missingBarID = "safari-bar"

    public let name = "Safari"
    public var onChange: (() -> Void)?
    public let plistURL: URL

    private let pollInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastSeenModification: Date?

    public static var defaultPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    public init(plistURL: URL = SafariAdapter.defaultPlistURL, pollInterval: TimeInterval = 2) {
        self.plistURL = plistURL
        self.pollInterval = pollInterval
    }

    deinit { timer?.cancel() }

    public var isAvailable: Bool {
        guard let handle = try? FileHandle(forReadingFrom: plistURL) else { return false }
        try? handle.close()
        return true
    }

    public var backupFiles: [URL] { [plistURL] }

    // MARK: Reading

    public func read() async throws -> Tree {
        let root = try load()
        let top = children(of: root)
        let barDict = top.first { isSpecial($0, "BookmarksBar") }
        let barID = barDict.flatMap(uuid) ?? Self.missingBarID
        var tree = Tree.empty(barID: barID, otherID: Self.otherRootID)

        func add(_ dict: NSMutableDictionary, to parent: String) {
            guard isVisible(dict), let id = uuid(dict) else { return }
            switch kind(dict) {
            case .folder:
                tree.nodes[id] = Node(id: id, title: dict["Title"] as? String ?? "", url: nil)
                tree.nodes[parent]?.children.append(id)
                for child in children(of: dict) { add(child, to: id) }
            case .bookmark:
                guard let url = dict["URLString"] as? String else { return }
                let title = (dict["URIDictionary"] as? NSDictionary)?["title"] as? String ?? url
                tree.nodes[id] = Node(id: id, title: title, url: url)
                tree.nodes[parent]?.children.append(id)
            case .other:
                return
            }
        }
        if let barDict { for child in children(of: barDict) { add(child, to: barID) } }
        for item in otherItems(root) { add(item, to: Self.otherRootID) }
        return tree
    }

    // MARK: Writing

    public func apply(_ ops: [NativeOp]) async throws -> [String: String] {
        guard !ops.isEmpty else { return [:] }
        let root = try load()
        var created: [String: String] = [:]
        func real(_ id: String) -> String { created[id] ?? id }

        for op in ops {
            switch op {
            case let .create(tempID, parent, index, title, url):
                let id = UUID().uuidString
                created[tempID] = id
                let dict = NSMutableDictionary()
                dict["WebBookmarkUUID"] = id
                if let url {
                    dict["WebBookmarkType"] = "WebBookmarkTypeLeaf"
                    dict["URLString"] = url
                    dict["URIDictionary"] = NSMutableDictionary(dictionary: ["title": title])
                } else {
                    dict["WebBookmarkType"] = "WebBookmarkTypeList"
                    dict["Title"] = title
                    dict["Children"] = NSMutableArray()
                }
                try insert(dict, into: real(parent), at: index, root: root)

            case let .update(id, title, url):
                guard let found = locate(real(id), in: root) else { throw SafariError.unknownID(id) }
                if kind(found.dict) == .folder {
                    found.dict["Title"] = title
                } else {
                    let uri = (found.dict["URIDictionary"] as? NSMutableDictionary) ?? NSMutableDictionary()
                    uri["title"] = title
                    found.dict["URIDictionary"] = uri
                    if let url { found.dict["URLString"] = url }
                }

            case let .move(id, parent, index):
                guard let found = locate(real(id), in: root) else { throw SafariError.unknownID(id) }
                found.siblings.removeObject(identicalTo: found.dict)
                try insert(found.dict, into: real(parent), at: index, root: root)

            case let .remove(id):
                guard let found = locate(real(id), in: root) else { continue }   // already gone
                found.siblings.removeObject(identicalTo: found.dict)
            }
        }

        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: plistURL, options: .atomic)
        // Our own write is not an outside change.
        noteCurrentModification()
        return created
    }

    // MARK: Watching

    /// Starts calling `onChange` when something other than this adapter changes the file.
    public func startWatching() {
        stopWatching()
        noteCurrentModification()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            guard let self, let now = self.modificationDate() else { return }
            self.lock.lock()
            let changed = self.lastSeenModification != now
            self.lastSeenModification = now
            self.lock.unlock()
            if changed { self.onChange?() }
        }
        t.resume()
        timer = t
    }

    public func stopWatching() {
        timer?.cancel()
        timer = nil
    }

    private func noteCurrentModification() {
        lock.lock()
        lastSeenModification = modificationDate()
        lock.unlock()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: plistURL.path))?[.modificationDate] as? Date
    }

    // MARK: Plist helpers

    private enum Kind { case folder, bookmark, other }

    private func load() throws -> NSMutableDictionary {
        let data: Data
        do { data = try Data(contentsOf: plistURL) } catch { throw SafariError.unreadable(error.localizedDescription) }
        let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)
        guard let root = plist as? NSMutableDictionary, root["Children"] is NSArray else { throw SafariError.malformed }
        return root
    }

    private func kind(_ dict: NSDictionary) -> Kind {
        switch dict["WebBookmarkType"] as? String {
        case "WebBookmarkTypeList": return .folder
        case "WebBookmarkTypeLeaf": return .bookmark
        default: return .other
        }
    }

    private func uuid(_ dict: NSDictionary) -> String? { dict["WebBookmarkUUID"] as? String }

    private func isSpecial(_ dict: NSDictionary, _ title: String) -> Bool {
        kind(dict) == .folder && dict["Title"] as? String == title
    }

    /// A folder's raw child array, created if the folder has none yet.
    private func rawChildren(of dict: NSMutableDictionary) -> NSMutableArray {
        if let array = dict["Children"] as? NSMutableArray { return array }
        let array = NSMutableArray()
        dict["Children"] = array
        return array
    }

    private func children(of dict: NSMutableDictionary) -> [NSMutableDictionary] {
        (dict["Children"] as? NSArray)?.compactMap { $0 as? NSMutableDictionary } ?? []
    }

    /// Whether a top-level item is one of the user's own, as opposed to a container Safari manages.
    private func isLoose(_ dict: NSDictionary) -> Bool {
        guard isVisible(dict) else { return false }
        return !["BookmarksBar", "BookmarksMenu", "com.apple.ReadingList"].contains { isSpecial(dict, $0) }
    }

    /// Whether an item takes part in sync. Reading and position arithmetic must agree on
    /// this, or inserts land one place off: folders and bookmarks with an ID, and for
    /// bookmarks a non-empty URL.
    private func isVisible(_ dict: NSDictionary) -> Bool {
        guard uuid(dict) != nil else { return false }
        switch kind(dict) {
        case .folder: return true
        case .bookmark: return !((dict["URLString"] as? String) ?? "").isEmpty
        case .other: return false
        }
    }

    private func menu(_ root: NSMutableDictionary) -> NSMutableDictionary? {
        children(of: root).first { isSpecial($0, "BookmarksMenu") }
    }

    /// The `.other` root's children: Bookmarks Menu contents, then loose top-level items.
    private func otherItems(_ root: NSMutableDictionary) -> [NSMutableDictionary] {
        (menu(root).map { children(of: $0).filter(isVisible) } ?? []) + children(of: root).filter(isLoose)
    }

    private func locate(_ id: String, in root: NSMutableDictionary) -> (dict: NSMutableDictionary, siblings: NSMutableArray)? {
        func search(_ parent: NSMutableDictionary) -> (NSMutableDictionary, NSMutableArray)? {
            guard let array = parent["Children"] as? NSMutableArray else { return nil }
            for case let child as NSMutableDictionary in array {
                if uuid(child) == id { return (child, array) }
                if kind(child) == .folder, let hit = search(child) { return hit }
            }
            return nil
        }
        return search(root)
    }

    /// Inserts so that `dict` ends up at position `index` among the parent's visible children.
    private func insert(_ dict: NSMutableDictionary, into parentID: String, at index: Int, root: NSMutableDictionary) throws {
        func place(in array: NSMutableArray, visibleIndex: Int, visible: (NSDictionary) -> Bool) {
            var seen = 0
            var lastVisibleRaw: Int?
            for (raw, item) in array.enumerated() {
                guard let d = item as? NSDictionary, visible(d) else { continue }
                if seen == visibleIndex { array.insert(dict, at: raw); return }
                seen += 1
                lastVisibleRaw = raw
            }
            array.insert(dict, at: lastVisibleRaw.map { $0 + 1 } ?? array.count)
        }

        if parentID == Self.otherRootID {
            let menuDict = menu(root)
            let menuCount = menuDict.map { children(of: $0).filter(isVisible).count } ?? 0
            // Position `menuCount` is both "end of Bookmarks Menu" and "before the first loose
            // item": the same place in the combined list. The menu is where Safari itself
            // puts new bookmarks, so it wins.
            if let menuDict, index <= menuCount {
                place(in: rawChildren(of: menuDict), visibleIndex: index, visible: isVisible)
            } else {
                place(in: rawChildren(of: root), visibleIndex: index - menuCount, visible: isLoose)
            }
            return
        }

        if parentID == Self.missingBarID {
            let bar = NSMutableDictionary(dictionary: [
                "Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString,
            ])
            let array = NSMutableArray(object: dict)
            bar["Children"] = array
            rawChildren(of: root).insert(bar, at: 0)
            return
        }

        guard let parent = locate(parentID, in: root), kind(parent.dict) == .folder else {
            throw SafariError.unknownID(parentID)
        }
        place(in: rawChildren(of: parent.dict), visibleIndex: index, visible: isVisible)
    }
}
