import Foundation

/// Chrome native messaging framing: a 4-byte little-endian length, then that many bytes of JSON.
public enum Frame {
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

/// Reassembles frames from a byte stream that may split or join them arbitrarily.
public struct FrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    public mutating func next() -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let payload = buffer.subdata(in: start..<(start + length))
        buffer = Data(buffer.dropFirst(4 + length))
        return payload
    }
}

public enum SocketError: Error { case failed(String) }

/// Thin wrappers over POSIX Unix-domain sockets.
public enum UnixSocket {
    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.failed("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Binds and listens, replacing any stale socket file at `path`.
    public static func listen(path: String) throws -> Int32 {
        let fd = try make()
        unlink(path)
        var addr = try address(path)
        guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else {
            close(fd)
            throw SocketError.failed("bind: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw SocketError.failed("listen: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = try make()
        var addr = try address(path)
        guard withSockaddr(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            throw SocketError.failed("connect: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// Blocks for the next chunk. `nil` or empty means the other end is gone.
    public static func read(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buffer, buffer.count)
        return n > 0 ? Data(buffer[0..<n]) : nil
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw SocketError.failed("write: \(String(cString: strerror(errno)))") }
                offset += n
            }
        }
    }
}
