import Foundation

public struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var summary: String

    public init(id: UUID = UUID(), date: Date = Date(), summary: String) {
        self.id = id
        self.date = date
        self.summary = summary
    }
}

public struct PendingCreate: Codable, Equatable, Sendable {
    /// Canonical ID of the folder it was created in.
    public var parent: String
    public var title: String
    public var url: String?
}

/// What the app remembers between syncs.
public struct SyncState: Codable, Sendable {
    /// Both browsers' bookmarks as of the last successful sync, in canonical IDs.
    public var base: Tree
    /// Adapter name → canonical ID → that browser's native ID.
    public var idMaps: [String: [String: String]]
    /// Newest first.
    public var activity: [ActivityEntry]
    /// Adapter name → canonical ID → a bookmark the app asked that browser to create
    /// but has not yet seen confirmed. If the write was cut off, the next read
    /// recognises these instead of taking them for new bookmarks.
    public var pendingCreates: [String: [String: PendingCreate]]?
    /// Adapter name → root kind → the browser's ID for that root folder at setup.
    public var rootIDs: [String: [String: String]]?
    /// Adapter name → `BrowserAdapter.identity` at setup.
    public var identities: [String: String]?

    public static let activityLimit = 200

    public init(base: Tree, idMaps: [String: [String: String]], activity: [ActivityEntry]) {
        self.base = base
        self.idMaps = idMaps
        self.activity = activity
    }
}

/// Files under one directory: `state.json` and `Backups/<timestamp>/`.
public final class StateStore {
    public static let backupLimit = 50
    public static let keptSuffix = "-setup"

    public let directory: URL
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var backupsURL: URL { directory.appendingPathComponent("Backups") }
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookmarkBridge")
    }

    public func load() throws -> SyncState? {
        guard fm.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL))
    }

    public func save(_ state: SyncState) throws {
        var state = state
        if state.activity.count > SyncState.activityLimit {
            state.activity = Array(state.activity.prefix(SyncState.activityLimit))
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// Writes one `<name>.json` per tree plus copies of `extraFiles`; returns the backup folder.
    @discardableResult
    public func writeBackup(trees: [String: Tree], extraFiles: [URL], keepForever: Bool = false) throws -> URL {
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        let stamp = formatter.string(from: Date())
        // Names sort chronologically; the counter keeps same-millisecond backups distinct and ordered.
        // `keepForever` backups (taken before setup replaces a browser's bookmarks) are
        // marked in the name and never rotated out.
        let suffix = keepForever ? Self.keptSuffix : ""
        var n = 0
        var folder: URL
        repeat {
            folder = backupsURL.appendingPathComponent(String(format: "%@-%03d%@", stamp, n, suffix))
            n += 1
        } while fm.fileExists(atPath: folder.path)
            || fm.fileExists(atPath: folder.path + Self.keptSuffix)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, tree) in trees {
            try JSONEncoder().encode(tree).write(to: folder.appendingPathComponent("\(name).json"))
        }
        for file in extraFiles where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        let rotating = listBackups().filter { !$0.lastPathComponent.hasSuffix(Self.keptSuffix) }
        for old in rotating.dropFirst(StateStore.backupLimit) { try? fm.removeItem(at: old) }
        return folder
    }

    /// Newest first.
    public func listBackups() -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        return items.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Adapter name → the tree saved in that backup.
    public func readBackup(_ folder: URL) throws -> [String: Tree] {
        var out: [String: Tree] = [:]
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            out[file.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode(Tree.self, from: Data(contentsOf: file))
        }
        return out
    }

    /// Forgets the sync state (so setup runs again). Backups are kept.
    public func reset() throws {
        if fm.fileExists(atPath: stateURL.path) { try fm.removeItem(at: stateURL) }
    }
}
