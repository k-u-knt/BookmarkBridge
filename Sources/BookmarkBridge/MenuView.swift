import SwiftUI
import SyncCore

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var restoreTarget: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if case let .confirm(removals, browser) = model.status {
                confirmation(removals: removals, browser: browser)
                Divider()
            }
            browsers
            Divider()
            activity
            Divider()
            actions
        }
        .frame(width: 320)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(statusTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func confirmation(removals: Int, browser: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Syncing now would remove \(removals) bookmarks from \(browser). A backup is saved first.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep Paused") { model.declineLargeRemoval() }
                Spacer()
                Button("Remove \(removals) Bookmarks") { model.confirmLargeRemoval() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
    }

    private var browsers: some View {
        VStack(spacing: 8) {
            browserRow(
                symbol: "safari", name: "Safari", ready: model.safariReady,
                detail: model.safariReady ? "Connected" : "Needs Full Disk Access"
            )
            browserRow(
                symbol: "globe", name: "Chrome", ready: model.chromeReady,
                detail: model.chromeReady ? "Connected" : "Not connected. Open Chrome, or finish setup."
            )
        }
        .padding(14)
    }

    private func browserRow(symbol: String, name: String, ready: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                .accessibilityLabel(ready ? "Connected" : "Not connected")
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Activity").font(.caption).foregroundStyle(.secondary)
            if model.activity.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(model.activity.prefix(8)) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.summary).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(entry.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isSetUp {
                Button {
                    Task { await model.sync() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isBusy)

                Toggle(isOn: $model.isPaused) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .toggleStyle(.button)
            } else {
                Button("Set Up…") { SetupWindow.show() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Menu {
                if model.isSetUp {
                    Menu("Restore from Backup") {
                        if model.backups.isEmpty { Text("No backups yet") }
                        ForEach(model.backups.prefix(12), id: \.self) { url in
                            Button(Self.backupLabel(url)) { restoreTarget = url }
                        }
                    }
                    .disabled(model.isBusy)
                    Button("Reset Sync…") { model.resetSync(); SetupWindow.show() }
                        .disabled(model.isBusy)
                    Divider()
                }
                Toggle("Launch at Login", isOn: $model.launchAtLogin)
                Divider()
                Button("Quit BookmarkBridge") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .confirmationDialog(
            "Restore both browsers to this backup?",
            isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }),
            presenting: restoreTarget
        ) { url in
            Button("Restore") {
                Task {
                    await model.restore(url)
                    SetupWindow.show()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Safari and Chrome each go back to their bookmarks from \(Self.backupLabel(url)). Today's bookmarks are backed up first. Sync then stops until you set it up again.")
        }
    }

    // MARK: Status text

    private var statusSymbol: String {
        switch model.status {
        case .needsSetup: return "bookmark"
        case .inSync: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .waiting: return "clock"
        case .attention, .confirm: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch model.status {
        case .inSync: return .green
        case .attention, .confirm: return .orange
        default: return .secondary
        }
    }

    private var statusTitle: String {
        switch model.status {
        case .needsSetup: return "Not set up yet"
        case .inSync: return "In sync"
        case .syncing: return "Syncing…"
        case .paused: return "Paused"
        case .waiting: return "Waiting"
        case .attention: return "Needs attention"
        case .confirm: return "Confirm removal"
        }
    }

    private var statusDetail: String {
        switch model.status {
        case .needsSetup: return "Choose which browser to copy from."
        case .inSync, .syncing:
            let count = "\(model.syncedCount) bookmarks"
            guard let last = model.lastSync else { return count }
            return "\(count) · checked \(last.formatted(.relative(presentation: .named)))"
        case .paused: return "Changes are not being synced."
        case let .waiting(why): return why
        case let .attention(why): return why
        case .confirm: return "Sync is on hold until you decide."
        }
    }

    static func backupLabel(_ url: URL) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        let stamp = String(url.lastPathComponent.prefix(23))
        guard let date = parser.date(from: stamp) else { return url.lastPathComponent }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
