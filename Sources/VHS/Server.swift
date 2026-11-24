import AppKit
import VHSCore

/// Turns the driver on in an app: `VHS.start()` listens on the socket named by `VHS_SOCKET` (or `DEBUG_SOCKET`) when
/// the app was launched with one, and does nothing otherwise. Call it once at launch, inside `#if DEBUG`.
public enum VHS {
    /// The environment variables a socket path is read from, first one set wins.
    public static let socketVariables = ["VHS_SOCKET", "DEBUG_SOCKET"]

    /// Commands of the app's own, beside the built-in ones: `name` is the first word of the line, and `run` gets the
    /// rest and returns what to answer (or throws, to answer with an error). It runs on the main actor.
    @MainActor public static func command(_ name: String, help: String, run: @escaping @MainActor (String) throws -> String) {
        Driver.shared.extra[name] = (help, run)
    }

    @MainActor public static func start(socket: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard let path = socket ?? socketVariables.lazy.compactMap({ env[$0] }).first(where: { !$0.isEmpty }) else { return }
        do {
            let fd = try Socket.listen(at: path)
            Driver.shared.socketPath = path
            Thread.detachNewThread { Socket.serve(fd) }
        } catch {
            NSLog("VHS: \(error)")
        }
        if let size = env["VHS_WINDOW_SIZE"], case .size(let w, let h)? = try? Drive.Command.parse("size \(size)") {
            // Later: start() runs from the app's init, before there is an NSApp.
            Task { @MainActor in resizeFirstWindow(width: w, height: h, tries: 100) }
        }
    }

    /// `VHS_WINDOW_SIZE=1440x900`: the first window, once it's open, made that size, so a recording has the same frame
    /// size whatever size the window was left at.
    @MainActor private static func resizeFirstWindow(width: Int, height: Int, tries: Int) {
        if NSApp != nil, !Driver.shared.windows().isEmpty {
            try? Driver.shared.resize(width: width, height: height)
            return
        }
        guard tries > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            resizeFirstWindow(width: width, height: height, tries: tries - 1)
        }
    }
}

/// The socket: plain BSD calls on a thread of its own, one connection at a time. A connection carries command lines;
/// each is answered with `ok`, perhaps followed by more, or `error: ` and why, as Typecase's driver answers.
enum Socket {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func listen(at path: String) throws -> Int32 {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(path)   // one left behind by a copy that crashed
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "can't listen on \(path): \(message)")
        }
        return fd
    }

    static func serve(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            converse(client)
            close(client)
        }
    }

    /// Reads lines until the client hangs up, answering each. A line runs here, off the main thread, so its waits
    /// leave the app drawing; what it does to the app hops onto the main thread.
    private static func converse(_ client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var finished = false
        while !finished {
            let n = read(client, &buffer, buffer.count)
            if n > 0 { pending.append(contentsOf: buffer[0..<n]) } else { finished = true }
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) ?? (finished && !pending.isEmpty ? pending.endIndex : nil) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending = newline < pending.endIndex ? Data(pending[(newline + 1)...]) : Data()
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let reply: String
                do {
                    let text = try Runner.run(line)
                    reply = text.isEmpty ? "ok" : "ok\n" + text
                } catch {
                    reply = "error: " + ((error as? Drive.Problem)?.description ?? "\(error)")
                }
                guard write(client, Data((reply + "\n").utf8)) else { return }
            }
        }
    }

    private static func write(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(client, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }
}

/// Runs a line on the socket thread: the pacing (waits, the beat after a step, the gap between typed keys) sleeps here,
/// and each thing done to the app is a hop to the main thread.
enum Runner {
    /// After each step of a recording, so a viewer sees what it did.
    static let beat = 0.12
    /// Between typed characters in a recording.
    static let keystroke = 0.055
    /// How long the pointer takes to glide to where it's going, in a recording.
    static let glide = 0.35
    /// A frame, for the glide's moves.
    static let frame = 1.0 / 60

    static func main<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated { try body() } }
    }

    static func run(_ line: String) throws -> String {
        let word = String(line.trimmingCharacters(in: .whitespaces).prefix(while: { !$0.isWhitespace }))
        if let extra = main({ Driver.shared.extra[word] }) {
            let rest = line.trimmingCharacters(in: .whitespaces).dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            return try main { try extra.run(rest) }
        }
        switch try Drive.Command.parse(line) {
        case .help:
            let extras = main { Driver.shared.extra.sorted { $0.key < $1.key }.map { $0.value.help } }
            return ([Drive.Command.helpText] + extras).joined(separator: "\n")
        case .steps(let steps):
            for step in steps { try perform(step) }
            return ""
        case .type(let text):
            try perform(.type(text))
            return ""
        case .shot(let path):
            Thread.sleep(forTimeInterval: 0.1)   // a few frames, for what takes one to lay out
            return try main { try Driver.shared.shot(to: URL(fileURLWithPath: path)) }
        case .record(let folder, let fps, let events):
            try main { try Driver.shared.record(to: URL(fileURLWithPath: folder), fps: fps, events: events) }
            return ""
        case .stop:
            let finish = try main { try Driver.shared.stop() }
            return String(try finish())
        case .windows:
            return main { Driver.shared.windowList() }
        case .window(let n):
            try main { try Driver.shared.choose(n) }
            return ""
        case .elements:
            return try main { try Driver.shared.elementList() }
        case .menu(let path):
            return try main { try Menus.follow(path) }
        case .size(let w, let h):
            try main { try Driver.shared.resize(width: w, height: h) }
            Thread.sleep(forTimeInterval: 0.2)   // for it to lay out
            return ""
        case .pid:
            return String(getpid())

        case .quit:
            main { Driver.shared.quit() }
            return ""
        }
    }

    /// Where a target is. SwiftUI updates what it tells accessibility a moment after a view changes, so a label or id
    /// that isn't there yet is looked for again for a second and a half.
    static func locate(_ target: Drive.Target) throws -> Driver.Point {
        let deadline = Date().addingTimeInterval(1.5)
        while true {
            do {
                return try main { try Driver.shared.locate(target) }
            } catch {
                if case .point = target { throw error }
                if Date() > deadline { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    static func perform(_ step: Drive.Step) throws {
        let recording = main { Driver.shared.isRecording }
        if case .wait(let ms) = step {
            Thread.sleep(forTimeInterval: Double(ms) / 1000)
            return
        }
        try focus()
        switch step {
        case .wait:
            return
        case .key(let key):
            try main { try Driver.shared.press(key) }
        case .type(let text):
            for c in text {
                try main { try Driver.shared.type(c) }
                if recording { Thread.sleep(forTimeInterval: keystroke) }
            }
        case .move(let target):
            let to = try locate(target)
            try glide(to, recording: recording)
            main { Driver.shared.note(.hover(x: to.x, y: to.y)) }
        case .click(let target, let right, let modifiers):
            let to = try locate(target)
            try glide(to, recording: recording)
            let held = (modifiers.isEmpty ? "" : modifiers + "-") + (right ? "right-" : "")
            let (down, up) = try main {
                Driver.shared.note(.click(x: to.x, y: to.y, held: held))
                return (Posted(try Driver.shared.mouse(down: true, at: to, right: right, modifiers: modifiers)),
                        Posted(try Driver.shared.mouse(down: false, at: to, right: right, modifiers: modifiers)))
            }
            down.post()
            Thread.sleep(forTimeInterval: recording ? 0.09 : 0.02)   // a press a viewer can see
            up.post()
        case .scroll(let target, let dy):
            let at = try locate(target)
            try glide(at, recording: recording)
            main { Driver.shared.note(.scroll(x: at.x, y: at.y, dy: dy)) }
            let slices = recording ? 10 : 1
            for _ in 0..<slices {
                try main { Posted(try Driver.shared.scroll(at: at, dy: dy / Double(slices))) }.post()
                if recording { Thread.sleep(forTimeInterval: 0.033) }
            }
        case .drag(let from, let to):
            let (a, b) = (try locate(from), try locate(to))
            try glide(a, recording: recording)
            try main {
                Driver.shared.note(.drag(x: a.x, y: a.y, x2: b.x, y2: b.y))
                return Posted(try Driver.shared.mouse(down: true, at: a, right: false, modifiers: ""))
            }.post()
            for i in 1...8 {
                let t = Double(i) / 8
                let at = Driver.Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                try main { Posted(try Driver.shared.dragged(to: at)) }.post()
                if recording { Thread.sleep(forTimeInterval: 0.033) }
            }
            try main { Posted(try Driver.shared.mouse(down: false, at: b, right: false, modifiers: "")) }.post()
        }
        Thread.sleep(forTimeInterval: recording ? beat : 0.03)
    }

    /// Waits for the app to be in front with the window key before input. An app can't bring itself forward (macOS
    /// leaves that to the user and to other processes), so the client does it: vhs-drive activates the app before
    /// the first line of input and gives the front back after.
    static func focus() throws {
        let deadline = Date().addingTimeInterval(3)
        while true {
            if try main({ try Driver.shared.focus() }) { return }
            if Date() > deadline {
                throw Drive.Problem("input needs the app in front, and it isn't: an app can't bring itself forward, "
                    + "so the client has to (vhs-drive does; `pid` gives what to activate)")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Moves the pointer to `to`: at once, unless recording, when it glides there by the clock.
    static func glide(_ to: Driver.Point, recording: Bool) throws {
        let from = main { Driver.shared.pointer } ?? to
        guard recording, from != to else {
            try main { Posted(try Driver.shared.moved(to: to)) }.post()
            return
        }
        let start = Date()
        while true {
            let t = min(Date().timeIntervalSince(start) / glide, 1)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let at = t >= 1 ? to : Driver.Point(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            try main { Posted(try Driver.shared.moved(to: at)) }.post()
            if t >= 1 { return }
            Thread.sleep(forTimeInterval: frame)
        }
    }
}

/// An event made on the main thread and posted to the app's queue from the socket thread.
/// Posted from the main queue, asynchronously: the socket thread doesn't wait, and the main queue is still served
/// while a control's tracking loop runs, so a release reaches a loop that is waiting for it.
struct Posted: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
    func post() {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { NSApp.postEvent(event, atStart: false) } }
    }
}
