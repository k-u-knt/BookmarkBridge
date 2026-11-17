// Chrome starts this helper when the BookmarkBridge extension calls connectNative().
// It only relays bytes: Chrome's stdin/stdout on one side, the app's socket on the other.
// Both sides use the same framing, so nothing is parsed here.
import ChromeAdapter
import Foundation

signal(SIGPIPE, SIG_IGN)

let socketFD: Int32
do {
    socketFD = try UnixSocket.connect(path: ChromeAdapter.defaultSocketURL.path)
} catch {
    // The app is not running. Exit; the extension retries later.
    exit(1)
}

Thread.detachNewThread {
    while let chunk = UnixSocket.read(socketFD) {
        do { try UnixSocket.writeAll(STDOUT_FILENO, chunk) } catch { break }
    }
    exit(0)
}

while let chunk = UnixSocket.read(STDIN_FILENO) {
    do { try UnixSocket.writeAll(socketFD, chunk) } catch { break }
}
exit(0)
