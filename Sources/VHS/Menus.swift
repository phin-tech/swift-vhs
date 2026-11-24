import AppKit
import VHSCore

@MainActor
enum Menus {
    /// Follows `path` through the main menu: an item at its end is chosen, as clicking it would; a menu is listed.
    /// Items that open a modal panel (Open…, Save…) stop the app answering until it closes, so leave those alone.
    static func follow(_ path: [String]) throws -> String {
        guard var menu = NSApp.mainMenu else { throw Drive.Problem("no menu bar") }
        for (i, title) in path.enumerated() {
            menu.update()
            guard let item = menu.items.first(where: { $0.title == title }) else {
                throw Drive.Problem("no “\(title)” in \(menu.items.map(\.title).filter { !$0.isEmpty })")
            }
            if let sub = item.submenu {
                menu = sub
                continue
            }
            guard i == path.count - 1 else { throw Drive.Problem("“\(title)” is an item, not a menu") }
            guard item.isEnabled else { throw Drive.Problem("“\(title)” is disabled") }
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
                throw Drive.Problem("“\(title)” did nothing")
            }
            return ""
        }
        menu.update()
        return menu.items.map { item in
            if item.isSeparatorItem { return "---" }
            let more = item.submenu != nil ? " >" : ""
            let off = item.isEnabled ? "" : "  (disabled)"
            let key = item.keyEquivalent.isEmpty ? "" : "  ⌘\(item.keyEquivalent)"
            return item.title + more + off + key
        }.joined(separator: "\n")
    }
}
