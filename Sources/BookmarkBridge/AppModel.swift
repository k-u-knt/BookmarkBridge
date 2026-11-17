import AppKit
import ChromeAdapter
import Foundation
import SafariAdapter
import ServiceManagement
import SyncCore

/// Everything the interface shows and does. Safari is side A, Chrome is side B.
@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case needsSetup
        case inSync
        case syncing
        case paused
        case waiting(String)                       // a browser is not reachable; nothing is wrong
        case attention(String)                     // something failed
        case confirm(removals: Int, browser: String)
    }

    @Published private(set) var status: Status = .needsSetup
    @Published private(set) var lastSync: Date?
    @Published private(set) var safariReady = false
    @Published private(set) var chromeReady = false
    @Published private(set) var syncedCount = 0
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var backups: [URL] = []
    @Published private(set) var isBusy = false
    @Published var isPaused: Bool = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "paused")
            refreshStatus()
            if !isPaused { requestSync() }
        }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = .attention("Could not change Launch at Login: \(error.localizedDescription)")
            }
        }
    }

    let safari = SafariAdapter()
    let chrome = ChromeAdapter()
    private let store = StateStore(directory: StateStore.defaultDirectory)
    private lazy var engine = SyncEngine(a: safari, b: chrome, store: store)

    private var lastChanged: Side = .a
    private var debounce: Task<Void, Never>?
    private var syncAgain = false
    private var timers: [Timer] = []

    var isSetUp: Bool { engine.isSetUp }

    nonisolated static var extensionFolder: URL { StateStore.defaultDirectory.appendingPathComponent("ChromeExtension") }

    init() {
        Installer.installChromePieces()
        do { try chrome.start() } catch { status = .attention("Could not start listening for Chrome: \(error.localizedDescription)") }

        safari.onChange = { [weak self] in Task { @MainActor in self?.noteChange(.a) } }
        chrome.onChange = { [weak self] in Task { @MainActor in self?.noteChange(.b) } }
        safari.startWatching()

        // Availability for the interface, and a safety sync in case a change notification was missed.
        // The availability check tries to open Safari's bookmarks file. Until access is
        // granted that attempt is refused, and it is also what makes macOS add this app
        // to the Full Disk Access list (switched off) for the person to turn on.
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        })
        refreshAvailability()
        reloadFromStore()
        refreshStatus()
        requestSync()
    }

    // MARK: Triggers

    private func noteChange(_ side: Side) {
        lastChanged = side
        refreshAvailability()
        requestSync()
    }

    /// Schedules an automatic sync shortly, collapsing bursts of changes into one.
    func requestSync() {
        guard isSetUp, !isPaused else { return }
        if case .confirm = status { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Syncs now. Used by the automatic path, the Sync Now button and the removal confirmation.
    func sync(confirmedRemovals: Int? = nil) async {
        guard isSetUp else { return }
        if isBusy { syncAgain = true; return }
        isBusy = true
        status = .syncing
        defer {
            isBusy = false
            if syncAgain { syncAgain = false; requestSync() }
        }
        do {
            switch try await engine.sync(prefer: lastChanged, confirmedRemovals: confirmedRemovals) {
            case .noChanges, .synced:
                lastSync = Date()
                reloadFromStore()
                status = isPaused ? .paused : .inSync
            case let .needsConfirmation(removals, browser):
                status = .confirm(removals: removals, browser: browser)
            case let .unavailable(name):
                status = .waiting(name == "Chrome"
                    ? "Waiting for Chrome. Changes will sync when it is open."
                    : "Waiting for \(name).")
            }
        } catch {
            status = .attention(error.localizedDescription)
        }
    }

    /// Agrees to exactly the number of removals that was shown. If more have piled up
    /// by the time the sync runs, it asks again.
    func confirmLargeRemoval() {
        guard case let .confirm(removals, _) = status else { return }
        status = .syncing
        Task { await sync(confirmedRemovals: removals) }
    }

    func declineLargeRemoval() {
        isPaused = true
    }

    // MARK: Setup, restore, reset

    func bookmarkCounts() async -> (safari: Int?, chrome: Int?) {
        let s = try? await safari.read().bookmarkCount
        let c = try? await chrome.read().bookmarkCount
        return (s, c)
    }

    func setUp(source: Side) async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        try await engine.setUp(source: source)
        lastSync = Date()
        reloadFromStore()
        refreshStatus()
    }

    func restore(_ backup: URL) async {
        guard !isBusy else { return }       // never alongside a sync: the engine has one writer
        debounce?.cancel()
        isBusy = true
        defer { isBusy = false }
        do {
            try await engine.restore(backup: backup)
            reloadFromStore()
            refreshStatus()
        } catch {
            status = .attention(error.localizedDescription)
        }
    }

    /// Forgets the pairing. Bookmarks in both browsers are left as they are.
    func resetSync() {
        guard !isBusy else { return }       // a running sync would save its state back
        debounce?.cancel()
        try? store.reset()
        reloadFromStore()
        refreshStatus()
    }

    // MARK: State for the interface

    private func refreshAvailability() {
        let s = safari.isAvailable, c = chrome.isAvailable
        if s != safariReady { safariReady = s }
        if c != chromeReady { chromeReady = c }
    }

    private func reloadFromStore() {
        let state = try? store.load()
        activity = state?.activity ?? []
        syncedCount = state?.base.bookmarkCount ?? 0
        backups = store.listBackups()
    }

    private func refreshStatus() {
        if !isSetUp { status = .needsSetup }
        else if isPaused { status = .paused }
        else if status == .needsSetup || status == .paused { status = .inSync }
    }

    var menuBarSymbol: String {
        switch status {
        case .needsSetup: return "bookmark"
        case .inSync: return "bookmark.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .waiting: return "bookmark.fill"
        case .attention, .confirm: return "exclamationmark.triangle.fill"
        }
    }
}

/// Puts the pieces Chrome needs where Chrome looks for them.
enum Installer {
    static let hostName = "io.github.k_u_knt.bookmarkbridge"

    static func installChromePieces() {
        let fm = FileManager.default
        guard let resources = Bundle.main.resourceURL else { return }
        let bundledExtension = resources.appendingPathComponent("ChromeExtension")
        guard fm.fileExists(atPath: bundledExtension.path) else { return }   // running outside the app bundle

        // 1. The extension, at a path that does not move when the app does.
        let dest = AppModel.extensionFolder
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: bundledExtension, to: dest)

        // 2. The native messaging manifest, telling Chrome which program the extension may start.
        guard let id = try? String(contentsOf: bundledExtension.appendingPathComponent("EXTENSION_ID"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bookmarkbridge-host")
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "BookmarkBridge",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ]
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? data.write(to: dir.appendingPathComponent("\(hostName).json"), options: .atomic)
        }
    }
}
