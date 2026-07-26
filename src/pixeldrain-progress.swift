// pixeldrain-progress — floating progress window for the "Upload to PixelDrain
// Folder…" Quick Action.
//
// Reads a one-line-per-message protocol on stdin and updates a floating panel:
//   TITLE    <text>        window title line
//   STATUS   <text>        status line
//   PROGRESS <0-100>       determinate progress
//   PROGRESS ind           indeterminate (animated) progress
//   DONE     <text>        completion message; window lingers ~4s then closes
//   DONEHOLD <text>        completion message; window stays open until Close
// stdin EOF closes the window (unless a completion message is showing).
//
// Args: argv[1] = orchestrator PID (Cancel back-channel), argv[2] = pause-file
// path (optional).
//
// Cancel back-channel: clicking Cancel (or the window close button / Esc) sends
// SIGTERM to the orchestrator PID; it traps it, aborts the in-flight upload,
// cleans up, and closes its end of the pipe — which reaches us as stdin EOF and
// we exit. This coordinated shutdown is why Cancel waits for EOF.
//
// Pause back-channel: the Pause button toggles the pause file between "1" and
// "0". The orchestrator polls it at each file boundary and holds/resumes.

import Cocoa
import Darwin

let parentPID: pid_t = CommandLine.arguments.count > 1
    ? (pid_t(CommandLine.arguments[1]) ?? 0) : 0
let pausePath: String? = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2] : nil

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

final class ProgressController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let panel: NSPanel
    let titleLabel = makeLabel(bold: true)
    let statusLabel = makeLabel(bold: false)
    let bar = NSProgressIndicator()
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let button = NSButton(title: "Cancel", target: nil, action: nil)

    var finished = false     // DONE / DONEHOLD received
    var cancelling = false
    var paused = false

    override init() {
        let w: CGFloat = 520, h: CGFloat = 150
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = "PixelDrain"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let content = panel.contentView!

        titleLabel.frame = NSRect(x: 20, y: 112, width: w - 40, height: 20)
        titleLabel.stringValue = "Uploading to PixelDrain…"

        statusLabel.frame = NSRect(x: 20, y: 62, width: w - 40, height: 40)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.stringValue = "Starting…"

        bar.frame = NSRect(x: 20, y: 30, width: 290, height: 20)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 100
        bar.startAnimation(nil)

        pauseButton.frame = NSRect(x: 320, y: 24, width: 85, height: 32)
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.isHidden = (pausePath == nil)

        button.frame = NSRect(x: 415, y: 24, width: 85, height: 32)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(cancelClicked)
        button.keyEquivalent = "\u{1b}"   // Esc

        content.addSubview(titleLabel)
        content.addSubview(statusLabel)
        content.addSubview(bar)
        content.addSubview(pauseButton)
        content.addSubview(button)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel.center()
        panel.orderFrontRegardless()
        startReading()
    }

    // ---- stdin reader ----
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
        case "TITLE":
            titleLabel.stringValue = rest
        case "STATUS":
            if !cancelling { statusLabel.stringValue = rest }
        case "PROGRESS":
            if cancelling { break }
            if rest == "ind" {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            } else if let v = Double(rest) {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
                bar.doubleValue = min(100, max(0, v))
            }
        case "DONE":
            complete(rest, hold: false)
        case "DONEHOLD":
            complete(rest, hold: true)
        default:
            break
        }
    }

    func complete(_ msg: String, hold: Bool) {
        finished = true
        cancelling = false
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = 100
        statusLabel.stringValue = msg
        pauseButton.isHidden = true
        button.title = "Close"
        button.isEnabled = true
        button.keyEquivalent = "\r"
        // Small uploads auto-close after a readable pause; big ones (hold) stay
        // open until the user clicks Close.
        if !hold {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
        }
    }

    func stdinClosed() {
        // A completion message schedules/awaits its own close; let it stand.
        if finished { return }
        NSApp.terminate(nil)
    }

    // ---- pause ----
    @objc func pauseClicked() {
        guard let path = pausePath, !finished, !cancelling else { return }
        paused.toggle()
        try? (paused ? "1" : "0").write(toFile: path, atomically: true, encoding: .utf8)
        pauseButton.title = paused ? "Resume" : "Pause"
    }

    // ---- cancel ----
    @objc func cancelClicked() {
        if finished {              // button now reads "Close"
            NSApp.terminate(nil)
            return
        }
        guard !cancelling else { return }
        cancelling = true
        button.isEnabled = false
        pauseButton.isHidden = true
        statusLabel.stringValue = "Cancelling…"
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        if parentPID > 0 { kill(parentPID, SIGTERM) }
        // Fallback in case the parent never closes the pipe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelClicked()
        return false   // coordinated shutdown closes us via stdin EOF
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = ProgressController()
app.delegate = controller
app.run()
