import AppKit
import ApplicationServices
import VHSCore

/// What a window exposes to accessibility, read through the accessibility API on this process's own elements, which
/// needs no Accessibility permission. Asking this way is also what makes SwiftUI build its accessibility tree, which it
/// leaves empty until something asks. Controls give their label, title and identifier here, which is how
/// `click Label` and `click #id` find them.
@MainActor
enum Elements {
    struct Element {
        var role: String
        var label: String?
        var title: String?
        var identifier: String?
        /// In screen points from the top-left of the main screen, as accessibility gives it.
        var frame: CGRect
    }

    static func all(in window: NSWindow) -> [Element] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2)
        let windows: [AXUIElement] = value(app, kAXWindowsAttribute) ?? []
        // The window is the one whose frame is this window's.
        let target = top(window.frame)
        guard let root = windows.first(where: { frame(of: $0).map { abs($0.minX - target.minX) < 2 && abs($0.minY - target.minY) < 2 } ?? false })
            ?? windows.first else { return [] }
        var out: [Element] = []
        func visit(_ e: AXUIElement, depth: Int) {
            guard depth < 60, out.count < 5000 else { return }
            let role: String = value(e, kAXRoleAttribute) ?? "?"
            if let f = frame(of: e), f.width > 0, f.height > 0 {
                out.append(Element(role: role,
                                   label: nonEmpty(value(e, kAXDescriptionAttribute)),
                                   title: nonEmpty(value(e, kAXTitleAttribute)) ?? nonEmpty(value(e, kAXValueAttribute).flatMap { (v: String) in v }),
                                   identifier: nonEmpty(value(e, kAXIdentifierAttribute)),
                                   frame: f))
            }
            for child: AXUIElement in value(e, kAXChildrenAttribute) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return out
    }

    static func find(in window: NSWindow, _ matches: (Element) -> Bool) -> [Element] {
        all(in: window).filter(matches)
    }

    /// The middle of the one element found, in the window's points from its top-left.
    static func center(of found: [Element], named: String, in window: NSWindow) throws -> Driver.Point {
        guard let first = found.first else {
            throw Drive.Problem("nothing is \(named); `elements` lists what the window exposes")
        }
        // The same control can be exposed twice (a button and its text); they share a place, so any will do, but two
        // in different places is ambiguous.
        let places = Set(found.map { "\(Int($0.frame.midX)),\(Int($0.frame.midY))" })
        if places.count > 1 {
            throw Drive.Problem("\(places.count) things are \(named); name one by #id or click its X,Y")
        }
        let r = rect(first.frame, in: window)
        return Driver.Point(x: r.midX, y: r.midY)
    }

    /// An accessibility rectangle in the window's points, from its top-left.
    static func rect(_ screen: CGRect, in window: NSWindow) -> CGRect {
        let w = top(window.frame)
        return CGRect(x: screen.minX - w.minX, y: screen.minY - w.minY, width: screen.width, height: screen.height)
    }

    /// An AppKit screen rectangle (from the bottom-left) as accessibility measures one (from the top-left).
    private static func top(_ r: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let p: AXValue = value(e, kAXPositionAttribute), let s: AXValue = value(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &point)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func value<T>(_ e: AXUIElement, _ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
