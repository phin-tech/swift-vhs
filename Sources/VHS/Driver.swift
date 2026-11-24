import AppKit
import VHSCore

/// The app's side of the driver, on the main actor: which window commands act on, where the pointer is, and the
/// recording, if one is running.
@MainActor
final class Driver {
    static let shared = Driver()

    struct Point: Equatable { var x: Double; var y: Double }

    var extra: [String: (help: String, run: @MainActor (String) throws -> String)] = [:]
    var socketPath: String?
    /// The window commands act on, by its place in `windows`; nil is the front one.
    private var chosen: Int?
    /// Where the pointer is, in the window's points from its top-left; nil until something moves it.
    private(set) var pointer: Point?
    private var recording: Recording?
    var isRecording: Bool { recording != nil }
    var currentRecording: Recording? { recording }

    // MARK: Windows

    /// Visible windows with something in them, front to back.
    func windows() -> [NSWindow] {
        guard NSApp != nil else { return [] }
        return NSApp.orderedWindows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 1 }
    }

    func window() throws -> NSWindow {
        let all = windows()
        guard !all.isEmpty else { throw Drive.Problem("no window is open") }
        let n = chosen ?? 0
        guard all.indices.contains(n) else { throw Drive.Problem("there's no window \(n): \(all.count) are open, from 0") }
        return all[n]
    }

    func choose(_ n: Int?) throws {
        let old = chosen
        chosen = n
        do { _ = try window() } catch { chosen = old; throw error }
    }

    /// `* 0  1240×760 @2x  Title`, as Typecase's driver writes it; the size is the frame's, title bar and all, in
    /// points, which is what a recording's frames show and its events are measured in.
    func windowList() -> String {
        let current = try? window()
        let lines = windows().enumerated().map { n, w in
            let mark = w === current ? "*" : " "
            return "\(mark) \(n)  \(Int(w.frame.width))×\(Int(w.frame.height)) @\(Int(w.backingScaleFactor))x  \(w.title)"
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
    }

    func resize(width: Int, height: Int) throws {
        let window = try window()
        guard !isRecording else { throw Drive.Problem("not while recording: a recording's frames are one size") }
        let f = window.frame
        window.setFrame(NSRect(x: f.minX, y: f.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)),
                        display: true)
    }

    func quit() {
        if let socketPath { unlink(socketPath) }   // so a client started now waits for the next copy
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }

    // MARK: Focus

    /// Whether the app is in front with the window commands act on as its key window, making it key if the app is in
    /// front. AppKit treats a click in a window that isn't key as the one that brings it forward, and most views
    /// ignore that click, so input waits for this.
    func focus() throws -> Bool {
        let window = try window()
        guard NSApp.isActive else { return false }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        return window.isKeyWindow
    }

    // MARK: Pictures

    func shot(to url: URL) throws -> String {
        let image = try Capture.image(of: window())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Capture.png(image).write(to: url)
        return "\(image.width)×\(image.height)"
    }

    func record(to folder: URL, fps: Int, events: Bool) throws {
        guard recording == nil else { throw Drive.Problem("already recording; `stop` first") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recording = Recording(window: try window(), folder: folder, fps: fps, events: events)
    }

    /// Stops taking frames and returns what to wait on, off the main thread, for the last of them to be written; that
    /// answers with how many frames there are.
    func stop() throws -> @Sendable () throws -> Int {
        guard let recording else { throw Drive.Problem("not recording") }
        self.recording = nil
        return recording.finish()
    }

    /// Notes an event on the next frame a recording saves.
    func note(_ event: Drive.Event) {
        recording?.note(event)
    }

    // MARK: Finding things

    /// Where a target is, in the window's points from its top-left.
    func locate(_ target: Drive.Target) throws -> Point {
        let window = try window()
        switch target {
        case .point(let x, let y):
            return Point(x: x, y: y)
        case .id(let id):
            return try Elements.center(of: Elements.find(in: window) { $0.identifier == id }, named: "#\(id)", in: window)
        case .label(let label):
            return try Elements.center(of: Elements.find(in: window) { $0.label == label || $0.title == label },
                                       named: "“\(label)”", in: window)
        }
    }

    func elementList() throws -> String {
        let window = try window()
        return Elements.all(in: window).map { e in
            let r = Elements.rect(e.frame, in: window)
            var line = "\(e.role)"
            if let id = e.identifier, !id.isEmpty { line += " #\(id)" }
            if let l = e.label ?? e.title, !l.isEmpty { line += " “\(l)”" }
            return line + "  \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
        }.joined(separator: "\n")
    }

    // MARK: Doing things

    /// The events for these return to be posted off the main thread (see `Input.mouse`).
    func moved(to at: Point) throws -> NSEvent {
        pointer = at
        return try Input.mouse(.mouseMoved, at: at, in: window())
    }

    func dragged(to at: Point) throws -> NSEvent {
        pointer = at
        return try Input.mouse(.leftMouseDragged, at: at, in: window())
    }

    func mouse(down: Bool, at: Point, right: Bool, modifiers: String) throws -> NSEvent {
        pointer = at
        let type: NSEvent.EventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        return try Input.mouse(type, at: at, in: window(), modifiers: Input.flags(modifiers.split(separator: "-").map(String.init)))
    }

    func scroll(at: Point, dy: Double) throws -> NSEvent {
        try Input.scroll(at: at, dy: dy, in: window())
    }

    func press(_ key: String) throws {
        note(.key(key))
        try Input.key(key, in: window())
    }

    func type(_ c: Character) throws {
        note(.key(Drive.typedKey(c)))
        try Input.type(c, in: window())
    }
}
