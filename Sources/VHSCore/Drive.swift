import Foundation

/// The lines a VHS driver answers to, read the way Typecase's driver reads them (its `crates/drive`), so one
/// script runs against a GPUI app, a web page or this app, and demoreel's `record` drives any of them. The contract is
/// demoreel's docs/adr/0001-drivers-share-one-recording-contract.md. The app side is the VHS target; this is
/// the reading and the events file, which need no AppKit.
public enum Drive {
    /// What a click or a move is aimed at.
    public enum Target: Equatable, Sendable {
        /// A point in the window, in points from its top-left corner (the title bar included, as in a frame).
        case point(x: Double, y: Double)
        /// The element whose accessibility identifier is this.
        case id(String)
        /// The element whose accessibility label or title is exactly this.
        case label(String)

        /// Reads `120,40` as a point, `#save` as an id and anything else as a label.
        public static func parse(_ text: String) throws -> Target {
            let text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { throw Problem("a click needs somewhere to click: X,Y, #id or a label") }
            if text.hasPrefix("#") { return .id(String(text.dropFirst())) }
            let parts = text.split(separator: ",", maxSplits: 1)
            if parts.count == 2,
               let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                return .point(x: x, y: y)
            }
            return .label(text)
        }

        var isNumber: Bool {
            if case .label(let l) = self { return Double(l) != nil }
            return false
        }
    }

    /// One thing done to the window, as a person would do it.
    public enum Step: Equatable, Sendable {
        /// A keystroke such as `j`, `enter` or `cmd-k`.
        case key(String)
        /// A click, holding modifiers (`cmd`, `cmd-shift`) or none.
        case click(Target, right: Bool, modifiers: String)
        /// The pointer moves there.
        case move(Target)
        /// Text typed a character at a time into whatever has focus.
        case type(String)
        /// Time passing, in milliseconds, with the window drawing.
        case wait(Int)
        /// What's at a point scrolling by `dy` points, down when it's positive.
        case scroll(Target, dy: Double)
        /// A press at one place, dragged to another.
        case drag(from: Target, to: Target)

        /// Reads one step: `j`, `cmd-k`, `click:X,Y`, `click:#id`, `cmd-click:…`, `right-click:…`, `move:…`,
        /// `type:word`, `scroll:X,Y,DY`, `drag:X1,Y1,X2,Y2`, `wait` (half a second) or `wait:250`.
        public static func parse(_ word: String) throws -> Step {
            if word == "wait" { return .wait(500) }
            if let ms = word.dropPrefix("wait:") {
                guard let n = Int(ms), n >= 0 else { throw Problem("`\(word)`: a wait is in whole milliseconds, as wait:250") }
                return .wait(n)
            }
            if let text = word.dropPrefix("type:") { return .type(text) }
            if let target = word.dropPrefix("move:") { return .move(try Target.parse(target)) }
            if let rest = word.dropPrefix("scroll:") {
                let bad = Problem("`\(word)`: a scroll is scroll:X,Y,DY or scroll:#id,DY")
                guard let comma = rest.lastIndex(of: ","),
                      let dy = Double(rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)) else { throw bad }
                let target = try Target.parse(String(rest[..<comma]))
                if target.isNumber { throw bad }
                return .scroll(target, dy: dy)
            }
            if let rest = word.dropPrefix("drag:") {
                let bad = Problem("`\(word)`: a drag is drag:X1,Y1,X2,Y2 or drag:#from,#to")
                let numbers = rest.split(separator: ",", omittingEmptySubsequences: false)
                let from: String, to: String
                if numbers.count == 4, numbers.allSatisfy({ Double($0.trimmingCharacters(in: .whitespaces)) != nil }) {
                    from = "\(numbers[0]),\(numbers[1])"
                    to = "\(numbers[2]),\(numbers[3])"
                } else {
                    guard let comma = rest.firstIndex(of: ",") else { throw bad }
                    from = String(rest[..<comma])
                    to = String(rest[rest.index(after: comma)...])
                }
                let (a, b) = (try Target.parse(from), try Target.parse(to))
                if a.isNumber || b.isNumber { throw bad }
                return .drag(from: a, to: b)
            }
            if let range = word.range(of: "click:") {
                var held = String(word[..<range.lowerBound])
                let target = try Target.parse(String(word[range.upperBound...]))
                var right = false
                if held.hasSuffix("right-") {
                    right = true
                    held.removeLast("right-".count)
                }
                if !held.isEmpty && !held.hasSuffix("-") {
                    throw Problem("`\(word)`: modifiers go before the click, as cmd-click:X,Y")
                }
                if held.hasSuffix("-") { held.removeLast() }
                return .click(target, right: right, modifiers: held)
            }
            let key = word.hasSuffix("--") ? "-" : String(word.split(separator: "-", omittingEmptySubsequences: false).last ?? "")
            if key.count > 1 && !Drive.isNamedKey(key) {
                let held = word.dropLast(key.count).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let typed = held.split(separator: "-").allSatisfy({ Drive.modifierWords.contains(String($0)) }) ? key : word
                throw Problem("`\(word)` isn't a key: a word to type is `type:\(typed)`, or `type …` on a line of its own")
            }
            return .key(word)
        }

        /// Steps separated by spaces.
        public static func parseAll(_ text: String) throws -> [Step] {
            try text.split(whereSeparator: \.isWhitespace).map { try parse(String($0)) }
        }
    }

    /// One line sent to the driver.
    public enum Command: Equatable, Sendable {
        case help
        case steps([Step])
        /// The rest of the line typed, spaces and all.
        case type(String)
        /// The window drawn to a PNG at this path.
        case shot(String)
        /// Frames to this folder, this many a second, until `stop`; with `events`, no pointer is drawn and
        /// events.json is written beside them, numbered from 00000.
        case record(folder: String, fps: Int, events: Bool)
        case stop
        case windows
        /// Which window commands act on: one by its number, or nil for the frontmost.
        case window(Int?)
        /// What the window exposes to accessibility: roles, labels, ids and where they are.
        case elements
        /// The window resized to this many points, title bar and all, keeping its top-left corner where it is.
        case size(width: Int, height: Int)
        /// The app's process id, for a client to bring it forward before input.
        case pid
        /// The main menu followed along this path: an item at its end is chosen, a menu is listed.
        case menu([String])
        case quit

        public static let helpText = """
        help                 this
        <steps>              keys and clicks separated by spaces: j cmd-k enter click:X,Y click:#id click:Label
                             cmd-click:… right-click:… move:… type:word scroll:X,Y,DY drag:X1,Y1,X2,Y2 wait wait:250
        click <target>       X,Y in points from the window's top-left, #id, or an accessible label, which may have spaces
        right-click <target>
        type <text>          the rest of the line, typed into whatever has focus
        shot <file.png>      the window, drawn at its own scale
        record <folder> [fps] [--events]  frames (no pointer drawn) to the folder until stop, numbered from
                             00000; --events also writes events.json of what was done on which frame
        stop                 finishes the recording and says how many frames
        windows              every window and its size; * marks the one commands act on
        window <n|front>     which window commands act on (the front one, until told otherwise)
        elements             what the window exposes: roles, labels, ids and bounds
        menu [Top > Sub > Item]  lists the menu bar or a menu, or chooses the item the path ends at
        size <w> <h>         the window resized to w×h points, title bar and all (a recording's frame size)
        pid                  the app's process id
        quit
        """

        /// Whether the command clicks, types or moves: input, which an app only takes in front.
        public var isInput: Bool {
            switch self {
            case .type: return true
            case .steps(let steps): return steps.contains { if case .wait = $0 { return false } else { return true } }
            default: return false
            }
        }

        public static func parse(_ line: String) throws -> Command {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = line.prefix(while: { !$0.isWhitespace })
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            func path(_ what: String) throws -> String {
                if rest.isEmpty { throw Problem("`\(word)` needs \(what)") }
                return rest
            }
            switch word {
            case "": throw Problem("nothing to do")
            case "help": return .help
            case "click", "right-click":
                return .steps([.click(try Target.parse(rest), right: word == "right-click", modifiers: "")])
            case "type": return .type(rest)
            case "shot": return .shot(try path("a file to save to"))
            case "record":
                var rest = rest
                var events = false
                if rest == "--events" || rest.hasSuffix(" --events") {
                    events = true
                    rest = String(rest.dropLast("--events".count)).trimmingCharacters(in: .whitespaces)
                }
                var folder = rest, fps = 30
                if let space = rest.lastIndex(where: \.isWhitespace), let n = Int(rest[rest.index(after: space)...]) {
                    folder = rest[..<space].trimmingCharacters(in: .whitespaces)
                    fps = n
                }
                if folder.isEmpty { throw Problem("`record` needs a folder for the frames") }
                if fps < 1 || fps > 120 { throw Problem("a recording is 1 to 120 frames a second") }
                return .record(folder: folder, fps: fps, events: events)
            case "stop": return .stop
            case "windows": return .windows
            case "window":
                if rest.isEmpty || rest == "front" || rest == "newest" { return .window(nil) }
                guard let n = Int(rest) else { throw Problem("`window \(rest)`: a window is a number or `front`") }
                return .window(n)
            case "elements": return .elements
            case "pid": return .pid
            case "size":
                let parts = rest.split(whereSeparator: { $0.isWhitespace || $0 == "x" || $0 == "×" }).compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 >= 200 && $0 <= 8000 }) else {
                    throw Problem("`size` is a width and a height in points, as size 1280 800")
                }
                return .size(width: parts[0], height: parts[1])
            case "menu":
                return .menu(rest.isEmpty ? [] : rest.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) })
            case "quit": return .quit
            default: return .steps(try Step.parseAll(line))
            }
        }
    }

    /// One thing done, for events.json.
    public enum Event: Equatable, Sendable {
        case key(String)
        case click(x: Double, y: Double, held: String)
        case hover(x: Double, y: Double)
        case scroll(x: Double, y: Double, dy: Double)
        case drag(x: Double, y: Double, x2: Double, y2: Double)
        /// A menu item chosen (`menu File > Save`), its path as the menu bar shows it.
        case menu([String])
        /// A sound the app played (a file, from `from` seconds into it, for `seconds` or to its end), noted by the app.
        case sound(file: String, from: Double, seconds: Double?)
    }

    /// What a clean recording says was done on which frame, in the shape demoreel reads:
    /// `{"fps":30,"frames":N,"events":[{"frame":15,"kind":"key","key":"cmd-k"},…]}`.
    public struct Events: Sendable {
        public let fps: Int
        private var lines: [String] = []

        public init(fps: Int) { self.fps = fps }

        /// Notes `event` as happening on `frame`, the number of the first frame file that shows it.
        public mutating func note(_ frame: Int, _ event: Event) {
            func text(_ s: String) -> String {
                String(data: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
            }
            func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
            switch event {
            case .key(let key):
                lines.append(#"{"frame":\#(frame),"kind":"key","key":\#(text(key))}"#)
            case .click(let x, let y, let held):
                lines.append(#"{"frame":\#(frame),"kind":"click","x":\#(n(x)),"y":\#(n(y)),"held":\#(text(held))}"#)
            case .hover(let x, let y):
                lines.append(#"{"frame":\#(frame),"kind":"hover","x":\#(n(x)),"y":\#(n(y))}"#)
            case .scroll(let x, let y, let dy):
                lines.append(#"{"frame":\#(frame),"kind":"scroll","x":\#(n(x)),"y":\#(n(y)),"dy":\#(n(dy))}"#)
            case .drag(let x, let y, let x2, let y2):
                lines.append(#"{"frame":\#(frame),"kind":"drag","x":\#(n(x)),"y":\#(n(y)),"x2":\#(n(x2)),"y2":\#(n(y2))}"#)
            case .menu(let path):
                lines.append(#"{"frame":\#(frame),"kind":"menu","path":\#(text(path.joined(separator: " > ")))}"#)
            case .sound(let file, let from, let seconds):
                let length = seconds.map { #","seconds":\#(n($0))"# } ?? ""
                lines.append(#"{"frame":\#(frame),"kind":"sound","file":\#(text(file)),"from":\#(n(from))\#(length)}"#)
            }
        }

        /// The file's text, for a recording of `frames` frames.
        public func json(frames: Int) -> String {
            "{\"fps\":\(fps),\"frames\":\(frames),\"events\":[\n\(lines.joined(separator: ",\n"))\n]}\n"
        }
    }

    /// The name a typed character goes by as a key.
    public static func typedKey(_ c: Character) -> String {
        switch c {
        case " ": "space"
        case "\n": "enter"
        case "\t": "tab"
        default: String(c)
        }
    }

    /// Keys named in words, such as `enter` or `f5`, rather than a character.
    public static func isNamedKey(_ key: String) -> Bool {
        let names: Set = ["enter", "escape", "tab", "backspace", "delete", "space", "up", "down", "left", "right",
                          "home", "end", "pageup", "pagedown", "insert", "menu", "capslock"]
        if names.contains(key) { return true }
        if key.hasPrefix("f"), let n = Int(key.dropFirst()) { return (1...35).contains(n) }
        return false
    }

    static let modifierWords: Set = ["cmd", "ctrl", "alt", "shift", "fn", "super", "win", "control", "option", "platform"]

    /// Splits `cmd-shift-k` into its modifiers and its key; `cmd--` is Command and the minus key.
    public static func split(_ keystroke: String) -> (modifiers: [String], key: String) {
        if keystroke == "-" { return ([], "-") }
        if keystroke.hasSuffix("--") {
            return (keystroke.dropLast(2).split(separator: "-").map(String.init), "-")
        }
        var parts = keystroke.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let key = parts.removeLast()
        return (parts, key)
    }

    /// Reads a script: one command a line, with blank lines and `#` comments left out.
    public static func script(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public struct Problem: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
