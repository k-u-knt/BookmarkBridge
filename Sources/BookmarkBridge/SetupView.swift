import AppKit
import SwiftUI
import SyncCore

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    @State private var step = 0
    @State private var source: Side?
    @State private var counts: (safari: Int?, chrome: Int?) = (nil, nil)
    @State private var working = false
    @State private var error: String?
    @State private var confirming = false

    private let titles = ["Safari", "Chrome", "Direction"]

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 36).padding(.bottom, 20)
            Group {
                switch step {
                case 0: safariStep
                case 1: chromeStep
                default: directionStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520, height: 520)
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(titles.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                        if i < step {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == step ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(titles[i]).font(.callout).foregroundStyle(i == step ? .primary : .secondary)
                }
                if i < titles.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 32, height: 1)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1; error = nil }.disabled(working) }
            Spacer()
            if working { ProgressView().controlSize(.small).padding(.trailing, 6) }
            switch step {
            case 0:
                Button("Continue") { step = 1 }.disabled(!model.safariReady).keyboardShortcut(.defaultAction)
            case 1:
                Button("Continue") { step = 2; Task { counts = await model.bookmarkCounts() } }
                    .disabled(!model.chromeReady).keyboardShortcut(.defaultAction)
            default:
                Button("Start Syncing") { confirming = true }
                    .disabled(source == nil || working).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Steps

    private var safariStep: some View {
        stepBody(
            symbol: "safari",
            title: "Let BookmarkBridge read Safari's bookmarks",
            text: "Safari keeps its bookmarks in a protected file. macOS only lets an app open it when the app has Full Disk Access."
        ) {
            checklist([
                "Open the Full Disk Access list with the button below.",
                "Turn on BookmarkBridge. It has already asked macOS for access, so it should be in the list.",
                "If macOS asks, choose Quit & Reopen.",
            ])
            HStack(spacing: 12) {
                Button("Open Full Disk Access Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .keyboardShortcut(model.safariReady ? nil : .defaultAction)
            }
            if !model.safariReady {
                // Fallback when macOS has not listed the app by itself: the icon carries
                // the app's own location, so dropping it on the list adds exactly this copy.
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 44, height: 44)
                        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                        .help("Drag into the Full Disk Access list")
                        .accessibilityLabel("BookmarkBridge app icon, draggable")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not in the list?").font(.callout.weight(.medium))
                        Text("Drag this icon into the list, then turn it on.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(Bundle.main.bundlePath)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
            }
            readiness(model.safariReady, yes: "Safari's bookmarks are readable.", no: "Waiting for Full Disk Access…")
        }
    }

    private var chromeStep: some View {
        stepBody(
            symbol: "globe",
            title: "Add the helper extension to Chrome",
            text: "Chrome only lets its own extensions change bookmarks, so BookmarkBridge comes with a small one. It talks to this app and nothing else."
        ) {
            checklist([
                "In Chrome, open chrome://extensions and turn on Developer mode (top right).",
                "Click Load unpacked and choose the ChromeExtension folder.",
            ])
            HStack {
                Button("Open Chrome Extensions") { openChromeExtensions() }
                Button("Show Extension Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.extensionFolder])
                }
            }
            readiness(model.chromeReady, yes: "Chrome is connected.", no: "Waiting for the extension to connect… (up to 30 seconds)")
        }
    }

    private var directionStep: some View {
        stepBody(
            symbol: "arrow.left.arrow.right",
            title: "Which bookmarks do you want to keep?",
            text: "This choice is only for the first copy. Afterwards, changes in either browser go to the other."
        ) {
            HStack(spacing: 12) {
                directionCard(.a, from: "Safari", to: "Chrome", fromCount: counts.safari, toCount: counts.chrome)
                directionCard(.b, from: "Chrome", to: "Safari", fromCount: counts.chrome, toCount: counts.safari)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Replace and Start Syncing") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both browsers are backed up first. You can undo this later from Restore from Backup.")
        }
    }

    private var confirmTitle: String {
        guard let source else { return "" }
        let (from, to) = source == .a ? ("Safari", "Chrome") : ("Chrome", "Safari")
        let replaced = source == .a ? counts.chrome : counts.safari
        let n = replaced.map { "\($0) " } ?? ""
        return "Replace \(to)'s \(n)bookmarks with \(from)'s?"
    }

    private func directionCard(_ side: Side, from: String, to: String, fromCount: Int?, toCount: Int?) -> some View {
        let selected = source == side
        return Button {
            source = side
            error = nil
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(from) → \(to)").font(.headline)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text("Keep \(from)'s \(fromCount.map(String.init) ?? "…") bookmarks.")
                    .font(.callout)
                Text("\(to)'s \(toCount.map(String.init) ?? "…") are replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Building blocks

    private func stepBody<Content: View>(symbol: String, title: String, text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Color.accentColor).frame(width: 36)
                Text(title).font(.title3.bold())
            }
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func checklist(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(item).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private func readiness(_ ready: Bool, yes: String, no: String) -> some View {
        HStack(spacing: 8) {
            if ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(ready ? yes : no).font(.callout).foregroundStyle(ready ? .primary : .secondary)
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    private func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let url = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private func start() {
        guard let source else { return }
        working = true
        error = nil
        Task {
            do {
                try await model.setUp(source: source)
                close()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
