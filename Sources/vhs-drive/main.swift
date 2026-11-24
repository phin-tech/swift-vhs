// vhs-drive: sends commands to an app running VHS, runs scripts of them, and records a script. Its commands and flags
// are typecase-drive's, so demoreel's `record` block runs it as it runs that one ("drive": "vhs-drive").

import AppKit
import VHSCore

let usage = """
usage: vhs-drive [--socket PATH] [--wait SECONDS] <command>
       vhs-drive [--socket PATH] [--wait SECONDS] run <script>
       vhs-drive [--socket PATH] [--wait SECONDS] demo <script> <folder> --events [--fps N]
       vhs-drive [--socket PATH] [--wait SECONDS] demo <script> <out.mp4|out.gif> [--fps N] [--keep-frames]

The socket is --socket, or else $VHS_SOCKET, or $DEBUG_SOCKET. --wait waits up to that long for the app to answer
first. A script is one command a line; `#` starts a comment. `vhs-drive help` asks the app what it answers to.
A demo with --events leaves the frames and events.json in the folder, for demoreel; without it, the frames are made a
video with ffmpeg.
"""

struct Failure: Error { var message: String }

func send(_ socket: String, _ line: String) throws -> String {
    let line = absolutePaths(line)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socket.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure(message: "socket path too long: \(socket)") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        throw Failure(message: "couldn't reach the app at \(socket): \(String(cString: strerror(errno)))")
    }
    let out = Array((line + "\n").utf8)
    var sent = 0
    while sent < out.count {
        let n = out[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard n > 0 else { throw Failure(message: "couldn't send `\(line)`") }
        sent += n
    }
    shutdown(fd, SHUT_WR)
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0..<n])
    }
    let text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .newlines)
    if text.hasPrefix("ok") {
        return String(text.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \n"))
    }
    if text.hasPrefix("error: ") { throw Failure(message: String(text.dropFirst(7))) }
    throw Failure(message: text.isEmpty ? "the app closed the connection without answering" : text)
}

/// A relative path in `shot` or `record` made absolute, since the app's working folder isn't ours.
func absolutePaths(_ line: String) -> String {
    let line = line.trimmingCharacters(in: .whitespaces)
    let word = line.prefix(while: { !$0.isWhitespace })
    let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
    guard word == "shot" || word == "record", !rest.isEmpty, !rest.hasPrefix("/") else { return line }
    return "\(word) \(FileManager.default.currentDirectoryPath)/\(rest)"
}

/// Input only reaches an app in front, and an app can't bring itself forward, so before the first line of input the
/// client brings it forward, and gives the front back to whoever had it when it's done. Both go through Launch
/// Services (`open -a`), as a click in the Dock would: macOS honours that every time, where a request from a process
/// that isn't itself in front (`NSRunningApplication.activate`) is up to it.
enum Focus {
    nonisolated(unsafe) static var app: NSRunningApplication?
    nonisolated(unsafe) static var previous: NSRunningApplication?

    /// Before each line of input: brings the app forward if it isn't in front (the first time, or after something else
    /// took the front during a script), remembering who had it the first time.
    static func before(_ line: String, socket: String) throws {
        guard (try? Drive.Command.parse(line))?.isInput == true else { return }
        if app == nil {
            guard let pid = Int32(try send(socket, "pid")), let target = NSRunningApplication(processIdentifier: pid) else {
                throw Failure(message: "the app didn't say its process id")
            }
            app = target
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != pid { previous = front }
        }
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        bringForward(app)
        let deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func giveBack() {
        guard let previous, !previous.isTerminated else { return }
        Focus.previous = nil
        bringForward(previous)
    }

    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate(options: [])
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", url.path]
        try? open.run()
        open.waitUntilExit()
    }
}

func waitFor(_ socket: String, seconds: Double) throws {
    let deadline = Date().addingTimeInterval(seconds)
    var last = ""
    while Date() < deadline {
        do {
            let windows = try send(socket, "windows")
            if !windows.isEmpty { return }
            last = "no window is open yet"
        } catch let f as Failure {
            last = f.message
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw Failure(message: "the app didn't answer in \(seconds)s: \(last)")
}

func runScript(_ socket: String, _ text: String) throws {
    let debug = ProcessInfo.processInfo.environment["VHS_DEBUG"] != nil
    for line in Drive.script(text) {
        let started = Date()
        defer {
            if debug { FileHandle.standardError.write(Data(String(format: "%6.0fms  %@\n", Date().timeIntervalSince(started) * 1000, line).utf8)) }
        }
        do {
            try Focus.before(line, socket: socket)
            let reply = try send(socket, line)
            if !reply.isEmpty { print(reply) }
        } catch let f as Failure {
            throw Failure(message: "`\(line)`: \(f.message)")
        }
    }
}

func tool(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    do { try p.run() } catch { throw Failure(message: "couldn't run \(args[0]): \(error); is it installed?") }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure(message: "\(args[0]) failed (\(p.terminationStatus))") }
}

func demo(_ socket: String, script: String, out: String, fps: Int, events: Bool, keepFrames: Bool) throws {
    let outURL = URL(fileURLWithPath: out, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    let folder: URL
    if events {
        folder = outURL
    } else {
        guard ["mp4", "gif"].contains(outURL.pathExtension.lowercased()) else {
            throw Failure(message: "\(out): a demo is a .gif or an .mp4, or a folder with --events")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vhs-drive-\(getpid())")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // A script with input runs with the app in front, so it's brought forward before the first frame, not part-way in.
    if Drive.script(script).contains(where: { (try? Drive.Command.parse($0))?.isInput == true }) {
        try Focus.before("click 0,0", socket: socket)
        Thread.sleep(forTimeInterval: 0.3)   // for the window to draw as the active one
    }
    _ = try send(socket, "record \(folder.path) \(fps)" + (events ? " --events" : ""))
    var ran: Error?
    do { try runScript(socket, script) } catch { ran = error }
    // The recording stops even when a line failed, so the app isn't left saving frames.
    let count = try send(socket, "stop")
    if let ran { throw ran }
    FileHandle.standardError.write(Data("\(count) frames in \(folder.path)\n".utf8))
    if events {
        FileHandle.standardError.write(Data("wrote \(folder.appendingPathComponent("events.json").path)\n".utf8))
        return
    }
    let pattern = folder.appendingPathComponent("%05d.png").path
    if outURL.pathExtension.lowercased() == "gif" {
        try tool(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "\(fps)", "-i", pattern, "-vf",
                  "scale=iw/2:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                  outURL.path])
    } else {
        try tool(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "\(fps)", "-i", pattern,
                  "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                  outURL.path])
    }
    if !keepFrames { try? FileManager.default.removeItem(at: folder) }
    FileHandle.standardError.write(Data("wrote \(outURL.path)\n".utf8))
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let env = ProcessInfo.processInfo.environment
    var socket = env["VHS_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? env["DEBUG_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
    var wait: Double?
    var fps = 30
    var events = false
    var keepFrames = false
    var words: [String] = []
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help":
            print(usage)
            return
        case "--socket":
            guard !args.isEmpty else { throw Failure(message: "--socket needs a path") }
            socket = args.removeFirst()
        case "--wait":
            guard let s = args.first.flatMap(Double.init) else { throw Failure(message: "--wait needs a number of seconds") }
            args.removeFirst()
            wait = s
        case "--fps":
            guard let n = args.first.flatMap(Int.init) else { throw Failure(message: "--fps needs a number") }
            args.removeFirst()
            fps = n
        case "--events": events = true
        case "--keep-frames": keepFrames = true
        default: words.append(arg)
        }
    }
    guard let socket else { throw Failure(message: "no socket: pass --socket or set VHS_SOCKET") }
    if let wait { try waitFor(socket, seconds: wait) }
    func read(_ path: String) throws -> String {
        do { return try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw Failure(message: "couldn't read \(path): \(error.localizedDescription)") }
    }
    switch words.first {
    case nil:
        throw Failure(message: usage)
    case "run":
        guard words.count == 2 else { throw Failure(message: "usage: vhs-drive run <script>") }
        try runScript(socket, try read(words[1]))
    case "demo":
        guard words.count == 3 else { throw Failure(message: "usage: vhs-drive demo <script> <folder> --events") }
        try demo(socket, script: try read(words[1]), out: words[2], fps: fps, events: events, keepFrames: keepFrames)
    default:
        let line = words.joined(separator: " ")
        try Focus.before(line, socket: socket)
        let reply = try send(socket, line)
        if !reply.isEmpty { print(reply) }
    }
}

do {
    defer { Focus.giveBack() }
    try main()
} catch let f as Failure {
    FileHandle.standardError.write(Data("vhs-drive: \(f.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("vhs-drive: \(error)\n".utf8))
    exit(1)
}
