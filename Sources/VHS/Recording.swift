import AppKit
import VHSCore

/// Frames of one window, taken on the main run loop as often as the rate asks, and written as PNGs on other threads.
/// A frame that took longer than the interval is saved as many times as frames were due, so the video keeps the app's
/// own pace, as Typecase's recorder does. Frames are numbered from 00000, the same numbers events.json uses.
@MainActor
final class Recording {
    private let window: NSWindow
    private let folder: URL
    private let fps: Int
    private var events: Drive.Events?
    private var sent = 0
    private let started = Date()
    private var timer: Timer?
    private let writing = DispatchGroup()
    private let writers = DispatchQueue(label: "vhs.frames", qos: .userInitiated, attributes: .concurrent)
    private let errors = Errors()

    init(window: NSWindow, folder: URL, fps: Int, events: Bool) {
        self.window = window
        self.folder = folder
        self.fps = fps
        self.events = events ? Drive.Events(fps: fps) : nil
        Capture.prepare(window)
        tick()
        let timer = Timer(timeInterval: 1 / Double(fps), repeats: true) { _ in
            MainActor.assumeIsolated { Driver.shared.tickRecording() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func note(_ event: Drive.Event) {
        events?.note(sent, event)
    }

    func tick() {
        guard let image = try? Capture.image(of: window) else { return }
        let due = Int(Date().timeIntervalSince(started) * Double(fps)) + 1
        guard due > sent else { return }
        let numbers = Array(sent..<due)
        sent = due
        let box = ImageBox(image)
        let folder = folder, errors = errors
        writing.enter()
        writers.async { [writing] in
            defer { writing.leave() }
            do {
                let png = Capture.png(box.image)
                for n in numbers {
                    try png.write(to: folder.appendingPathComponent(String(format: "%05d.png", n)))
                }
            } catch {
                errors.add("\(error)")
            }
        }
    }

    /// Stops the timer now; what it returns waits for the writers and writes events.json, off the main thread.
    func finish() -> @Sendable () throws -> Int {
        timer?.invalidate()
        timer = nil
        let (writing, errors, folder, events, sent) = (writing, errors, folder, events, sent)
        return {
            writing.wait()
            if let first = errors.first { throw Drive.Problem("couldn't save a frame: \(first)") }
            if let events {
                let url = folder.appendingPathComponent("events.json")
                do { try events.json(frames: sent).write(to: url, atomically: true, encoding: .utf8) }
                catch { throw Drive.Problem("couldn't write \(url.path): \(error)") }
            }
            return sent
        }
    }
}

extension Driver {
    /// The timer's tick, which reaches the recording through the driver so the timer holds nothing of its own.
    func tickRecording() { currentRecording?.tick() }
}

private final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private final class Errors: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ e: String) { lock.lock(); list.append(e); lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return list.first }
}
