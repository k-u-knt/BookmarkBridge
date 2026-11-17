import Foundation

/// One edit to a browser's bookmarks, expressed in that browser's own IDs.
public enum NativeOp: Codable, Equatable, Sendable {
    /// `tempID` stands for the new node in later ops of the same batch
    /// (as `parent`, or as `id`) until the browser assigns a real ID.
    case create(tempID: String, parent: String, index: Int, title: String, url: String?)
    case update(id: String, title: String, url: String?)
    /// `index` is the position the node should end up at among its new siblings.
    case move(id: String, parent: String, index: Int)
    /// Removes the node and everything beneath it.
    case remove(id: String)
}

/// Everything the sync engine needs from a browser. Adding a browser means
/// writing one of these; the engine does not change.
public protocol BrowserAdapter: AnyObject {
    var name: String { get }
    /// False when the browser's bookmarks cannot be reached right now.
    var isAvailable: Bool { get }
    /// The browser's current bookmarks, in its native IDs.
    func read() async throws -> Tree
    /// Applies `ops` in order. Returns tempID → native ID for each `create`.
    func apply(_ ops: [NativeOp]) async throws -> [String: String]
    /// Called (on any thread) when the browser's bookmarks may have changed.
    var onChange: (() -> Void)? { get set }
    /// Raw files worth copying into a backup alongside the parsed tree.
    var backupFiles: [URL] { get }
    /// Tells one bookmark store from another (for example, one Chrome profile from
    /// another). Known after the first `read()`; `nil` if the browser has only one.
    var identity: String? { get }
}

extension BrowserAdapter {
    public var backupFiles: [URL] { [] }
    public var identity: String? { nil }
}
