import Foundation
import ApplicationServices

enum MenuControl {
    static func invoke(_ action: String) throws -> [String: Any] {
        let win = try WindowFinder.find()
        let title: String
        switch action {
        case "home":
            title = "Home Screen"
        case "app_switcher":
            title = "App Switcher"
        case "spotlight":
            title = "Spotlight"
        default:
            throw MirrorError.invalidArgs("unknown menu action: \(action)")
        }
        guard WindowFinder.accessibilityTrusted(prompt: true) else {
            throw MirrorError.permission("Accessibility permission is required for iPhone Mirroring commands")
        }
        try pressMenu(title: title, pid: win.pid)
        return [
            "ok": true,
            "action": action,
            "menuItem": title,
            "backend": "accessibility-menu",
            "axPressConfirmed": true,
        ]
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
}
