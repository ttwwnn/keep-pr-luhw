// Press a menu item or a button of a running app through the accessibility
// tree — no mouse, no keys, nothing the person at the machine would feel.
//
//   axpress <app name> menu <menu> <item>     e.g. axpress KeepDev menu File "Close Tab"
//   axpress <app name> button <title>         e.g. axpress KeepDev button "Close Tab"
//
// A button is looked for in every window of the app, sheets included, which
// is where a question before closing lives. Exits 0 when it pressed
// something, 1 when there was nothing by that name.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write("usage: axpress <app> menu <menu> <item> | axpress <app> button <title>\n".data(using: .utf8)!)
    exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == arguments[1] })
else { exit(1) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("axpress: not trusted for accessibility\n".data(using: .utf8)!)
    exit(3)
}

func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, "AXChildren") as? [AXUIElement] ?? []
}
func title(_ element: AXUIElement) -> String? { attribute(element, "AXTitle") as? String }
func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

let root = AXUIElementCreateApplication(app.processIdentifier)
switch arguments[2] {
case "menu" where arguments.count >= 5:
    guard let bar = attribute(root, "AXMenuBar") else { exit(1) }
    let barElement = bar as! AXUIElement
    for top in children(barElement) where title(top) == arguments[3] {
        for menu in children(top) {
            for item in children(menu) where title(item) == arguments[4] {
                exit(press(item) ? 0 : 1)
            }
        }
    }
    exit(1)
case "button":
    var visited = 0
    func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        visited += 1
        guard depth < 40, visited < 20_000 else { return nil }
        if (attribute(element, "AXRole") as? String) == "AXButton", title(element) == arguments[3] {
            return element
        }
        for child in children(element) {
            if let hit = find(child, depth + 1) { return hit }
        }
        return nil
    }
    for window in attribute(root, "AXWindows") as? [AXUIElement] ?? [] {
        if let button = find(window, 0) { exit(press(button) ? 0 : 1) }
    }
    exit(1)
default:
    exit(2)
}
