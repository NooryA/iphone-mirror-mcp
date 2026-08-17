import Foundation
import ApplicationServices
import AppKit

enum MenuControl {
    static func invoke(_ action: String) throws -> [String: Any] {
        let win = try WindowFinder.find()
        let title: String
        let keyCode: CGKeyCode
        switch action {
        case "home":
            title = "Home Screen"
            keyCode = 18
        case "app_switcher":
            title = "App Switcher"
            keyCode = 19
        case "spotlight":
            title = "Spotlight"
            keyCode = 20
        default:
            throw MirrorError.invalidArgs("unknown menu action: \(action)")
        }
        guard WindowFinder.accessibilityTrusted(prompt: true) else {
            throw MirrorError.permission("Accessibility permission is required for iPhone Mirroring commands")
        }
        do {
            try pressMenu(title: title, pid: win.pid)
            return ["ok": true, "action": action, "menuItem": title, "backend": "accessibility-menu"]
        } catch {
            try pressShortcut(keyCode: keyCode, pid: win.pid)
            return ["ok": true, "action": action, "menuItem": title, "backend": "command-shortcut"]
        }
    }

    private static func pressMenu(title: String, pid: pid_t) throws {
        let app = AXUIElementCreateApplication(pid)
        var barRef: AnyObject?
        let barErr = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef)
        guard barErr == .success, let bar = barRef else {
            throw MirrorError.permission("could not read iPhone Mirroring menu bar")
        }
        var menusRef: AnyObject?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &menusRef)
        guard let menus = menusRef as? [AXUIElement] else {
            throw MirrorError.permission("no menu bar children")
        }
        for menuBarItem in menus {
            var menuRef: AnyObject?
            AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &menuRef)
            guard let menuKids = menuRef as? [AXUIElement], let menu = menuKids.first else { continue }
            var itemsRef: AnyObject?
            AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef)
            guard let items = itemsRef as? [AXUIElement] else { continue }
            for item in items {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
                let itemTitle = titleRef as? String ?? ""
                if itemTitle == title {
                    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    if err != .success {
                        throw MirrorError.permission("AXPress failed for \(title) (\(err.rawValue))")
                    }
                    return
                }
            }
        }
        throw MirrorError.invalidArgs("menu item '\(title)' not found")
    }

    private static func pressShortcut(keyCode: CGKeyCode, pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw MirrorError.invalidArgs("could not create iPhone Mirroring keyboard shortcut")
        }
        app.activate()
        usleep(80_000)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }
}
