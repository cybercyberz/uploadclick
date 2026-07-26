// pixeldrain-picker — native destination-folder browser for the "Upload to
// PixelDrain Folder…" Quick Action.
//
// A single persistent AppKit window using NSBrowser (macOS Finder column view):
// opening a folder slides a new column in to the right, so the window never
// re-pops or re-centers the way the old AppleScript `choose from list` did.
// "New Folder" and "Copy vs Move" are in-window sheets — nothing else pops.
//
// This binary is a pure view layer. The zsh orchestrator (pixeldrain-upload-fs)
// remains the controller and the only thing that talks to PixelDrain: the picker
// asks it for a directory's contents and it streams them back. All network and
// API-key handling stays in zsh/Python.
//
// Protocol (one message per line):
//   orchestrator → picker (stdin)
//     STATUS <text>     transient status shown on the loading overlay
//     BEGIN  <path>     start of a listing for <path> (clears the loading overlay)
//     DIR    <name>     a subfolder in the listing currently BEGUN
//     FILE   <name>     a file in the listing currently BEGUN (shown dimmed)
//     END    <path>     listing for <path> complete → (re)load its column
//     ERROR  <text>     fatal error → show it, then exit on the user's OK
//     CLOSE             orchestrator is done with us → exit 0
//   picker → orchestrator (stdout)
//     LIST   <path>                 need this folder's children
//     CHOOSE <copy|move> <path>     user confirmed a destination + mode
//     CANCEL                        user cancelled / closed the window
//
// <path> uses the orchestrator's own form ("me", "me/photos") and round-trips
// verbatim, so folder names with spaces are safe.

import Cocoa
import Darwin

// A node in the remote directory tree. NSBrowser's item-based API compares items
// by object identity, so every path maps to exactly one cached Node.
final class Node {
    let path: String     // "me", "me/photos"
    let name: String     // display name ("PixelDrain" for the root)
    let isDir: Bool
    var loaded = false
    var loading = false
    var children: [Node] = []
    init(path: String, name: String, isDir: Bool) {
        self.path = path; self.name = name; self.isDir = isDir
    }
}

// Plain backdrop that hides the empty browser while the first listing loads.
// draw(_:) re-reads windowBackgroundColor each time, so it tracks light/dark.
final class BackdropView: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

func makeLabel(bold: Bool) -> NSTextField {
    let f = NSTextField()
    f.isEditable = false
    f.isBordered = false
    f.isSelectable = false
    f.drawsBackground = false
    f.lineBreakMode = .byTruncatingTail
    f.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
    f.textColor = bold ? .labelColor : .secondaryLabelColor
    return f
}

final class PickerController: NSObject, NSApplicationDelegate, NSBrowserDelegate, NSWindowDelegate {
    let window: NSWindow
    let browser = NSBrowser()
    let overlay = BackdropView()
    let spinner = NSProgressIndicator()
    let statusLabel = makeLabel(bold: false)
    let destLabel = makeLabel(bold: false)
    let newFolderButton = NSButton(title: "New Folder…", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let uploadButton = NSButton(title: "Upload…", target: nil, action: nil)

    let root = Node(path: "me", name: "PixelDrain", isDir: true)
    var nodesByPath: [String: Node] = [:]
    var pendingChildren: [String: [Node]] = [:]   // path → children accumulated between BEGIN/END
    var beginPath: String? = nil                  // path of the listing currently streaming
    var finished = false                          // CHOOSE/CANCEL/ERROR sent → don't act further

    let out = FileHandle.standardOutput

    override init() {
        let w: CGFloat = 640, h: CGFloat = 440
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        nodesByPath["me"] = root

        window.title = "PixelDrain"
        window.delegate = self
        window.minSize = NSSize(width: 520, height: 340)
        window.level = .floating

        let content = window.contentView!
        let barH: CGFloat = 68

        // ---- browser (fills everything above the action bar) ----
        browser.frame = NSRect(x: 0, y: barH, width: w, height: h - barH)
        browser.autoresizingMask = [.width, .height]
        browser.delegate = self
        browser.target = self
        browser.action = #selector(browserClicked)
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = true
        browser.maxVisibleColumns = 3
        browser.minColumnWidth = 180
        content.addSubview(browser)

        // ---- loading overlay on top of the browser ----
        overlay.frame = browser.frame
        overlay.autoresizingMask = [.width, .height]
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.sizeToFit()
        spinner.frame = NSRect(x: (w - 32) / 2, y: (h - barH) / 2 + 6, width: 32, height: 32)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        spinner.startAnimation(nil)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 20, y: (h - barH) / 2 - 26, width: w - 40, height: 20)
        statusLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        statusLabel.stringValue = "Connecting to the PixelDrain Filesystem…"
        overlay.addSubview(spinner)
        overlay.addSubview(statusLabel)
        content.addSubview(overlay)

        // ---- action bar ----
        destLabel.frame = NSRect(x: 20, y: 40, width: w - 40, height: 18)
        destLabel.autoresizingMask = [.width, .maxYMargin]
        destLabel.stringValue = "Upload to: /"

        newFolderButton.frame = NSRect(x: 16, y: 8, width: 130, height: 28)
        newFolderButton.bezelStyle = .rounded
        newFolderButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolderClicked)

        uploadButton.frame = NSRect(x: w - 16 - 110, y: 8, width: 110, height: 28)
        uploadButton.bezelStyle = .rounded
        uploadButton.autoresizingMask = [.minXMargin, .maxYMargin]
        uploadButton.keyEquivalent = "\r"   // Return
        uploadButton.target = self
        uploadButton.action = #selector(uploadClicked)

        cancelButton.frame = NSRect(x: w - 16 - 110 - 8 - 90, y: 8, width: 90, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        cancelButton.keyEquivalent = "\u{1b}"   // Esc
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        content.addSubview(destLabel)
        content.addSubview(newFolderButton)
        content.addSubview(cancelButton)
        content.addSubview(uploadButton)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        browser.loadColumnZero()   // triggers numberOfChildrenOfItem(root) → LIST me
        startReading()
    }

    // ---- outgoing messages ----
    func send(_ s: String) {
        if let d = (s + "\n").data(using: .utf8) { out.write(d) }
    }

    // ---- stdin reader (background queue → main thread) ----
    func startReading() {
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { self.handle(line) }
            }
            DispatchQueue.main.async { self.stdinClosed() }
        }
    }

    func handle(_ line: String) {
        guard !line.isEmpty else { return }
        let cmd: String, rest: String
        if let sp = line.firstIndex(of: " ") {
            cmd = String(line[..<sp])
            rest = String(line[line.index(after: sp)...])
        } else {
            cmd = line
            rest = ""
        }

        switch cmd {
        case "STATUS":
            statusLabel.stringValue = rest
        case "BEGIN":
            if overlay.isHidden == false { hideOverlay() }
            beginPath = rest
            pendingChildren[rest] = []
        case "DIR":
            appendChild(name: rest, isDir: true)
        case "FILE":
            appendChild(name: rest, isDir: false)
        case "END":
            finishListing(rest)
        case "ERROR":
            showError(rest)
        case "CLOSE":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    func appendChild(name: String, isDir: Bool) {
        guard !name.isEmpty, let parent = beginPath else { return }
        let childPath = parent == "me" ? "me/\(name)" : "\(parent)/\(name)"
        pendingChildren[parent]?.append(nodeFor(path: childPath, name: name, isDir: isDir))
    }

    func finishListing(_ path: String) {
        guard let node = nodesByPath[path] else { return }
        node.children = pendingChildren[path] ?? []
        pendingChildren[path] = nil
        node.loaded = true
        node.loading = false
        if beginPath == path { beginPath = nil }
        // The column that displays a node's children sits at depth == slash count
        // of its path ("me" → 0, "me/photos" → 1).
        browser.reloadColumn(path.filter { $0 == "/" }.count)
        updateDestLabel()
    }

    func nodeFor(path: String, name: String, isDir: Bool) -> Node {
        if let n = nodesByPath[path] { return n }
        let n = Node(path: path, name: name, isDir: isDir)
        nodesByPath[path] = n
        return n
    }

    func hideOverlay() {
        spinner.stopAnimation(nil)
        overlay.isHidden = true
    }

    func stdinClosed() {
        // Orchestrator closed the pipe. If we already sent our decision it is a
        // normal shutdown; otherwise treat it as a cancel and exit.
        NSApp.terminate(nil)
    }

    // ---- NSBrowser data source (item-based, lazy) ----
    func rootItem(for browser: NSBrowser) -> Any? { return root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? Node) ?? root
        if !node.isDir { return 0 }
        if !node.loaded {
            if !node.loading { node.loading = true; send("LIST \(node.path)") }
            return 0
        }
        return node.children.count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? Node) ?? root
        return node.children[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.isDir
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        return (item as? Node)?.name ?? ""
    }

    // Dim files and make them unselectable so only folders can be picked.
    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let bc = cell as? NSBrowserCell else { return }
        if let node = browser.item(atRow: row, inColumn: column) as? Node {
            bc.isEnabled = node.isDir
            bc.isLeaf = !node.isDir
        }
    }

    // ---- destination tracking ----
    // The chosen folder is the selected folder in the right-most column that has
    // one; with no selection the destination is the root.
    func currentDestinationPath() -> String {
        let col = browser.selectedColumn
        guard col >= 0 else { return "me" }
        let row = browser.selectedRow(inColumn: col)
        guard row >= 0,
              let node = browser.item(atRow: row, inColumn: col) as? Node,
              node.isDir else { return "me" }
        return node.path
    }

    func displayPath(_ p: String) -> String {
        if p == "me" { return "/" }
        if p.hasPrefix("me/") { return "/" + p.dropFirst(3) }
        return "/" + p
    }

    func updateDestLabel() {
        destLabel.stringValue = "Upload to: \(displayPath(currentDestinationPath()))"
    }

    @objc func browserClicked(_ sender: NSBrowser) {
        updateDestLabel()
    }

    // ---- actions ----
    @objc func uploadClicked() {
        guard !finished else { return }
        confirmMode(for: currentDestinationPath(), newFolder: nil)
    }

    @objc func newFolderClicked() {
        guard !finished else { return }
        let base = currentDestinationPath()
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a new folder in \(displayPath(base))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "untitled folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.replacingOccurrences(of: "/", with: "")
            guard !name.isEmpty else { return }
            // Present the mode sheet on the next runloop tick so the first sheet
            // has fully dismissed before the second is attached to the window.
            DispatchQueue.main.async { self.confirmMode(for: base, newFolder: name) }
        }
        alert.window.initialFirstResponder = field
    }

    func confirmMode(for base: String, newFolder: String?) {
        let dest: String
        if let nf = newFolder {
            dest = base == "me" ? "me/\(nf)" : "\(base)/\(nf)"
        } else {
            dest = base
        }
        let alert = NSAlert()
        alert.messageText = "Upload into \(displayPath(dest))?"
        alert.informativeText = "Copy keeps the originals. Move deletes each local file after it uploads. In both modes, files already in the destination with the same name and size are skipped (Move leaves those on disk)."
        alert.addButton(withTitle: "Copy")    // default (rightmost)
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            switch resp {
            case .alertFirstButtonReturn:  self.choose("copy", dest)
            case .alertSecondButtonReturn: self.choose("move", dest)
            default: break   // Cancel: stay in the picker
            }
        }
    }

    func choose(_ mode: String, _ dest: String) {
        guard !finished else { return }
        finished = true
        send("CHOOSE \(mode) \(dest)")
        NSApp.terminate(nil)
    }

    @objc func cancelClicked() {
        guard !finished else { NSApp.terminate(nil); return }
        finished = true
        send("CANCEL")
        NSApp.terminate(nil)
    }

    // Fatal error from the orchestrator: show it, exit when the user acknowledges.
    func showError(_ msg: String) {
        finished = true
        hideOverlay()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "PixelDrain"
        alert.informativeText = msg
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in NSApp.terminate(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelClicked()
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PickerController()
app.delegate = controller
app.run()
