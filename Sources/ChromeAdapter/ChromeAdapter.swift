import Foundation
import SyncCore

public enum ChromeError: Error, Equatable, LocalizedError {
    case disconnected
    case timedOut
    case extensionFailed(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .disconnected: return "Chrome is not connected. It may be closed, or the BookmarkBridge extension may be missing."
        case .timedOut: return "Chrome did not answer in time."
        case let .extensionFailed(message): return "Chrome reported an error: \(message)"
        case .badResponse: return "Chrome sent an answer that could not be understood."
        }
    }
}

/// Chrome's bookmarks, through the BookmarkBridge extension.
///
/// The app listens on a Unix socket. Chrome starts `bookmarkbridge-host` when the
/// extension asks for it, and that helper relays bytes between Chrome and the socket.
/// Messages are JSON in Chrome's native messaging framing:
///
///     app → extension   {"id": n, "cmd": "getTree"}
///                       {"id": n, "cmd": "apply", "ops": [...]}
///     extension → app   {"id": n, "ok": true, "tree": {"bar": node, "other": node}}
///                       {"id": n, "ok": true, "created": {tempId: id}}
///                       {"id": n, "ok": false, "error": "..."}
///                       {"event": "changed"}
public final class ChromeAdapter: BrowserAdapter, @unchecked Sendable {
    public let name = "Chrome"
    public var onChange: (() -> Void)?
    /// Chrome caps a message to the extension at 1 MB, so long batches go in pieces.
    public static let opsPerMessage = 200
    /// The extension's per-profile ID, known after the first `read()`.
    public var identity: String? { locked { profileID } }
    private var profileID: String?

    private let socketURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    public static var defaultSocketURL: URL {
        StateStore.defaultDirectory.appendingPathComponent("chrome.sock")
    }

    public init(socketURL: URL = ChromeAdapter.defaultSocketURL, timeout: TimeInterval = 10) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    deinit { stop() }

    public var isAvailable: Bool { locked { clientFD >= 0 } }

    // MARK: Lifecycle

    /// Starts listening for the extension. Call once.
    public func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = try UnixSocket.listen(path: socketURL.path)
        locked { listenFD = fd }
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Only one Chrome profile talks to us; a new connection replaces the old one.
                let old: Int32 = self.locked { let o = self.clientFD; self.clientFD = client; return o }
                if old >= 0 { shutdown(old, SHUT_RDWR) }
                Thread.detachNewThread { [weak self] in self?.readLoop(client) }
                self.onChange?()
            }
        }
    }

    public func stop() {
        let (l, c): (Int32, Int32) = locked {
            let fds = (listenFD, clientFD)
            listenFD = -1
            clientFD = -1
            return fds
        }
        if c >= 0 { shutdown(c, SHUT_RDWR) }
        if l >= 0 {
            close(l)
            unlink(socketURL.path)
        }
    }

    private func readLoop(_ fd: Int32) {
        var reader = FrameReader()
        while let chunk = UnixSocket.read(fd) {
            reader.append(chunk)
            while let frame = reader.next() { handle(frame) }
        }
        close(fd)
        let orphans: [CheckedContinuation<Data, Error>] = locked {
            guard clientFD == fd else { return [] }
            clientFD = -1
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        orphans.forEach { $0.resume(throwing: ChromeError.disconnected) }
    }

    private func handle(_ frame: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { return }
        if message["event"] != nil {
            onChange?()
        } else if let id = message["id"] as? Int {
            locked { pending.removeValue(forKey: id) }?.resume(returning: frame)
        }
    }

    // MARK: Requests

    private func request(_ body: [String: Any]) async throws -> [String: Any] {
        let frame: Data = try await withCheckedThrowingContinuation { continuation in
            let (id, fd): (Int, Int32) = locked {
                let id = nextID
                nextID += 1
                if clientFD >= 0 { pending[id] = continuation }
                return (id, clientFD)
            }
            guard fd >= 0 else { return continuation.resume(throwing: ChromeError.disconnected) }
            var message = body
            message["id"] = id
            do {
                try UnixSocket.writeAll(fd, Frame.encode(try JSONSerialization.data(withJSONObject: message)))
            } catch {
                locked { pending.removeValue(forKey: id) }?.resume(throwing: ChromeError.disconnected)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.locked { self?.pending.removeValue(forKey: id) }?.resume(throwing: ChromeError.timedOut)
            }
        }
        guard let response = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
            throw ChromeError.badResponse
        }
        guard response["ok"] as? Bool == true else {
            throw ChromeError.extensionFailed(response["error"] as? String ?? "unknown error")
        }
        return response
    }

    public func read() async throws -> Tree {
        let response = try await request(["cmd": "getTree"])
        guard let tree = response["tree"] as? [String: Any],
              let bar = tree["bar"] as? [String: Any], let barID = bar["id"] as? String,
              let other = tree["other"] as? [String: Any], let otherID = other["id"] as? String
        else { throw ChromeError.badResponse }
        if let profile = tree["profile"] as? String { locked { profileID = profile } }

        var out = Tree.empty(barID: barID, otherID: otherID)
        func addChildren(of json: [String: Any], to parent: String) {
            for child in json["children"] as? [[String: Any]] ?? [] {
                guard let id = child["id"] as? String else { continue }
                let url = child["url"] as? String
                out.nodes[id] = Node(id: id, title: child["title"] as? String ?? "", url: url)
                out.nodes[parent]?.children.append(id)
                if url == nil { addChildren(of: child, to: id) }
            }
        }
        addChildren(of: bar, to: barID)
        addChildren(of: other, to: otherID)
        return out
    }

    public func apply(_ ops: [NativeOp]) async throws -> [String: String] {
        var created: [String: String] = [:]
        // The extension resolves temp IDs within one message; across messages it is done here.
        func real(_ id: String) -> String { created[id] ?? id }
        var start = 0
        while start < ops.count {
            let chunk = ops[start..<min(start + Self.opsPerMessage, ops.count)]
            start += Self.opsPerMessage
            let encoded: [[String: Any]] = chunk.map { op in
                switch op {
                case let .create(tempID, parent, index, title, url):
                    var d: [String: Any] = ["op": "create", "tempId": tempID, "parentId": real(parent), "index": index, "title": title]
                    if let url { d["url"] = url }
                    return d
                case let .update(id, title, url):
                    var d: [String: Any] = ["op": "update", "id": real(id), "title": title]
                    if let url { d["url"] = url }
                    return d
                case let .move(id, parent, index):
                    return ["op": "move", "id": real(id), "parentId": real(parent), "index": index]
                case let .remove(id):
                    return ["op": "remove", "id": real(id)]
                }
            }
            let response = try await request(["cmd": "apply", "ops": encoded])
            created.merge(response["created"] as? [String: String] ?? [:]) { _, new in new }
        }
        return created
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
