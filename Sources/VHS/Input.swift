import AppKit
import Carbon.HIToolbox
import VHSCore

/// Mouse and key events made in the app and handed to the window, as if a person had done them. Nothing goes through
/// the window server, so no permission is needed and the real pointer and keyboard are left alone.
@MainActor
enum Input {
    private static var number = 0

    /// The window's point from its top-left as AppKit's window coordinates, from its bottom-left.
    static func location(_ at: Driver.Point, in window: NSWindow) -> NSPoint {
        NSPoint(x: at.x, y: window.frame.height - at.y)
    }

    /// A mouse event for the window, to be posted to the app's queue (`NSApp.postEvent`, which any thread may call)
    /// rather than handed to the window inline: a control that tracks the mouse runs a loop inside its mouse-down that
    /// waits for the mouse-up, which has to come from the queue.
    static func mouse(_ type: NSEvent.EventType, at: Driver.Point, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        number += 1
        let down = type == .leftMouseDown || type == .rightMouseDown
        guard let event = NSEvent.mouseEvent(with: type, location: location(at, in: window), modifierFlags: modifiers,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                             clickCount: type == .mouseMoved || type == .leftMouseDragged ? 0 : 1,
                                             pressure: down ? 1 : 0) else {
            throw Drive.Problem("couldn't make a mouse event")
        }
        return event
    }

    static func scroll(at: Driver.Point, dy: Double, in window: NSWindow) throws -> NSEvent {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy.rounded()),
                               wheel2: 0, wheel3: 0) else { throw Drive.Problem("couldn't make a scroll event") }
        // CG counts screen points from the top-left of the main screen.
        let screen = window.convertPoint(toScreen: location(at, in: window))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: top - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { throw Drive.Problem("couldn't make a scroll event") }
        return event
    }

    /// A keystroke such as `j`, `cmd-k`, `shift-enter` or `space`. Shortcuts go where a real one would: the window's
    /// key equivalents (SwiftUI's `.keyboardShortcut`), then the main menu, then the focused view as a key press.
    static func key(_ keystroke: String, in window: NSWindow) throws {
        let (mods, name) = Drive.split(keystroke)
        let flags = flags(mods)
        guard let (code, characters) = Keys.lookup(name) else {
            throw Drive.Problem("`\(keystroke)`: there's no key \(name)")
        }
        let shown = flags.contains(.shift) ? characters.uppercased() : characters
        try send(code: code, characters: shown, unmodified: characters, flags: flags, in: window)
    }

    /// One typed character into whatever has focus.
    static func type(_ c: Character, in window: NSWindow) throws {
        let text = String(c)
        let (code, plain) = Keys.lookup(Drive.typedKey(c)) ?? Keys.lookup(text.lowercased()) ?? (0, text)
        let shifted = text != plain && text.lowercased() == plain
        try send(code: code, characters: text, unmodified: plain, flags: shifted ? .shift : [], in: window,
                 shortcuts: false)
    }

    private static func send(code: UInt16, characters: String, unmodified: String, flags: NSEvent.ModifierFlags,
                             in window: NSWindow, shortcuts: Bool = true) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: code) else {
                throw Drive.Problem("couldn't make a key event")
            }
            return e
        }
        let down = try event(.keyDown)
        if shortcuts {
            if window.performKeyEquivalent(with: down) { return }
            if !flags.intersection([.command, .control]).isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        }
        window.sendEvent(down)
        window.sendEvent(try event(.keyUp))
    }

    static func flags(_ words: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for w in words {
            switch w {
            case "cmd", "super", "platform", "win": f.insert(.command)
            case "ctrl", "control": f.insert(.control)
            case "alt", "option", "opt": f.insert(.option)
            case "shift": f.insert(.shift)
            case "fn": f.insert(.function)
            default: break
            }
        }
        return f
    }
}

/// Key codes and characters for the US layout, by the names Typecase uses.
enum Keys {
    static func lookup(_ name: String) -> (UInt16, String)? {
        if let named = named[name] { return named }
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) {
            let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                         kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            return (UInt16(codes[n - 1]), String(UnicodeScalar(NSF1FunctionKey + n - 1)!))
        }
        guard name.count == 1, let code = characters[name.lowercased()] else { return nil }
        return (UInt16(code), name.lowercased())
    }

    private static func function(_ k: Int) -> String { String(UnicodeScalar(k)!) }

    private static let named: [String: (UInt16, String)] = [
        "enter": (UInt16(kVK_Return), "\r"), "escape": (UInt16(kVK_Escape), "\u{1b}"), "tab": (UInt16(kVK_Tab), "\t"),
        "backspace": (UInt16(kVK_Delete), "\u{7f}"), "delete": (UInt16(kVK_ForwardDelete), function(NSDeleteFunctionKey)),
        "space": (UInt16(kVK_Space), " "),
        "up": (UInt16(kVK_UpArrow), function(NSUpArrowFunctionKey)), "down": (UInt16(kVK_DownArrow), function(NSDownArrowFunctionKey)),
        "left": (UInt16(kVK_LeftArrow), function(NSLeftArrowFunctionKey)), "right": (UInt16(kVK_RightArrow), function(NSRightArrowFunctionKey)),
        "home": (UInt16(kVK_Home), function(NSHomeFunctionKey)), "end": (UInt16(kVK_End), function(NSEndFunctionKey)),
        "pageup": (UInt16(kVK_PageUp), function(NSPageUpFunctionKey)), "pagedown": (UInt16(kVK_PageDown), function(NSPageDownFunctionKey)),
    ]

    private static let characters: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]
}
