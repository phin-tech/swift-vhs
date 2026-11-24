import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// A window's picture. An app may read its own windows from the window server without the Screen Recording
/// permission, which gives what is really there (materials, video, everything) in a few milliseconds, behind other
/// windows or not. That call (`CGWindowListCreateImage`) is deprecated, and unavailable to code built for macOS 15 or
/// later, so it is looked up at run time; if it's gone, the window is drawn the way printing draws it, which misses
/// materials and draws in each `AVPlayerLayer`'s frame itself.
@MainActor
enum Capture {
    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowImage: WindowImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImage.self)
    }()

    /// The window, title bar and all, at its backing scale.
    static func image(of window: NSWindow) throws -> CGImage {
        // .optionIncludingWindow, and .boundsIgnoreFraming | .bestResolution: the window alone, without its shadow.
        if let windowImage, window.windowNumber > 0,
           let image = windowImage(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue(),
           image.width > 1 {
            return image
        }
        return try drawn(window)
    }

    /// The frame view drawn the way printing draws it.
    static func drawn(_ window: NSWindow) throws -> CGImage {
        guard let content = window.contentView else { throw Failure("the window has no content") }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("could not make a bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        drawPlayers(of: view, into: rep)
        guard let image = rep.cgImage else { throw Failure("could not make an image") }
        return image
    }

    nonisolated static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// When the window has to be drawn: attaches outputs to the window's players ahead of a recording, so the first frames have their video.
    static func prepare(_ window: NSWindow) {
        guard windowImage == nil, let view = window.contentView?.superview ?? window.contentView else { return }
        for (layer, _) in players(in: view) { _ = output(for: layer) }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    // MARK: Video

    private static var outputs: [ObjectIdentifier: (item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = [:]
    private static var last: [ObjectIdentifier: CGImage] = [:]
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Every `AVPlayerLayer` under `view`, with the view whose layer tree holds it.
    private static func players(in view: NSView) -> [(AVPlayerLayer, NSView)] {
        var found: [(AVPlayerLayer, NSView)] = []
        func visit(_ v: NSView) {
            if v.isHiddenOrHasHiddenAncestor { return }
            if let layer = v.layer {
                // A subview's own layer is visited with it, so stop at layers that belong to subviews.
                let owned = Set(v.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
                func walkOwn(_ l: CALayer) {
                    if let p = l as? AVPlayerLayer { found.append((p, v)) }
                    for sub in l.sublayers ?? [] where !owned.contains(ObjectIdentifier(sub)) { walkOwn(sub) }
                }
                walkOwn(layer)
            }
            v.subviews.forEach(visit)
        }
        visit(view)
        return found
    }

    private static func output(for layer: AVPlayerLayer) -> AVPlayerItemVideoOutput? {
        guard let item = layer.player?.currentItem else { return nil }
        let key = ObjectIdentifier(layer)
        if let known = outputs[key], known.item === item { return known.output }
        if let old = outputs[key] { old.item.remove(old.output) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        outputs[key] = (item, output)
        last[key] = nil
        // A paused player has nothing new for a fresh output until it's asked for this frame again.
        if let player = layer.player, player.rate == 0 {
            player.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        return output
    }

    private static func frame(for layer: AVPlayerLayer) -> CGImage? {
        let key = ObjectIdentifier(layer)
        guard let output = output(for: layer), let item = layer.player?.currentItem else { return last[key] }
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time) || last[key] == nil,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let ci = CIImage(cvPixelBuffer: buffer)
            last[key] = context.createCGImage(ci, from: ci.extent)
        }
        return last[key]
    }

    private static func drawPlayers(of root: NSView, into rep: NSBitmapImageRep) {
        let found = players(in: root)
        guard !found.isEmpty, let ns = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = ns.cgContext
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        for (layer, host) in found {
            guard let image = frame(for: layer) else { continue }
            var rect = layer.videoRect
            if rect.isEmpty { rect = layer.bounds }
            // Into the host view's layer, whose geometry is the view's bounds, then into the root view.
            if let hostLayer = host.layer, hostLayer !== layer { rect = layer.convert(rect, to: hostLayer) }
            rect = host.convert(rect, to: root)
            cg.saveGState()
            cg.clip(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            cg.draw(image, in: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            cg.restoreGState()
        }
        ns.flushGraphics()
    }
}
