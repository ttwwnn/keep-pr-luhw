// Press a menu item or a button of a running app through the accessibility
// tree — no mouse, no keys, nothing the person at the machine would feel.
//
//   axpress <app name> menu <menu> <item>     e.g. axpress KeepDev menu File "Close Tab"
//   axpress <app name> button <title>         e.g. axpress KeepDev button "Close Tab"
//   axpress <app name> press <label>          any element: its title, description or identifier
//   axpress <app name> open <label>           open the menu of an element (a menu button is pressed)
//   axpress <app name> items                  the menu that is open: "mark<TAB>enabled<TAB>title"
//   axpress <app name> pick <title>           choose an item of the menu that is open
//   axpress <app name> cancel                 put the menu that is open away
//   axpress <app name> frame <label>          "x y w h" of an element, screen points from the top left
//   axpress <app name> value <label>          accessibility value of an element
//   axpress <app name> title <label>          its title (a button's text)
//   axpress <app name> enabled <label>        1 if it can be pressed, 0 if not
//   axpress <app name> menuenabled <menu> <item>  the same, for an item of the menu bar
//
// A button is looked for in every window of the app, sheets included, which
// is where a question before closing lives. Exits 0 when it did what it was
// asked, 1 when there was nothing by that name.
//
// Every question has a second to be answered. An app that puts a menu up in
// answer to a press is inside the menu until somebody chooses: asked from
// in there, a press that waited for its reply would wait for good. (Keep's
// menus open a turn after the press is answered, so they do not; a second is
// what keeps a regression from hanging the suite.)
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
let usage = """
    usage: axpress <app> menu <menu> <item> | button <title> | press <label> | open <label>
                   | items | pick <title> | cancel | frame <label> | value <label>
                   | title <label> | enabled <label> | menuenabled <menu> <item>

    """
guard arguments.count >= 3 else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == arguments[1] })
else { exit(1) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("axpress: not trusted for accessibility\n".data(using: .utf8)!)
    exit(3)
}
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, "AXChildren") as? [AXUIElement] ?? []
}
func title(_ element: AXUIElement) -> String? { attribute(element, "AXTitle") as? String }
func role(_ element: AXUIElement) -> String? { attribute(element, "AXRole") as? String }
func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}
func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1.0)

/// The first element, in any window, whose title, description or identifier
/// is `label`.
func element(labelled label: String) -> AXUIElement? {
    var visited = 0
    func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        visited += 1
        guard depth < 60, visited < 50_000 else { return nil }
        for key in ["AXTitle", "AXDescription", "AXIdentifier"] {
            if (attribute(element, key) as? String) == label { return element }
        }
        for child in children(element) {
            if let hit = find(child, depth + 1) { return hit }
        }
        return nil
    }
    for window in attribute(root, "AXWindows") as? [AXUIElement] ?? [] {
        if let hit = find(window, 0) { return hit }
    }
    return nil
}

/// The menu that is up, if one is. Looked for where it is cheapest first: a
/// pop-up menu is a child of the app while it is open (the menu bar's menus
/// are always in the tree, and are passed over); then the menu the focus is
/// in, since while a menu is up the focus is on it or one of its items; and
/// last down the windows, where a menu put up from a view can hang off it.
func openMenu() -> AXUIElement? {
    for child in children(root) where role(child) == "AXMenu" { return child }
    if let focused = attribute(root, "AXFocusedUIElement") {
        var element = focused as! AXUIElement
        for _ in 0..<6 {
            if role(element) == "AXMenu" {
                var up = element
                var inMenuBar = false
                for _ in 0..<6 {
                    guard let parent = attribute(up, "AXParent") else { break }
                    up = parent as! AXUIElement
                    if role(up) == "AXMenuBar" { inMenuBar = true; break }
                }
                if !inMenuBar { return element }
                break
            }
            guard let parent = attribute(element, "AXParent") else { break }
            element = parent as! AXUIElement
        }
    }
    var visited = 0
    func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        visited += 1
        guard depth < 60, visited < 50_000 else { return nil }
        for child in children(element) {
            if role(child) == "AXMenu" { return child }
            if let hit = find(child, depth + 1) { return hit }
        }
        return nil
    }
    for window in attribute(root, "AXWindows") as? [AXUIElement] ?? [] {
        if let menu = find(window, 0) { return menu }
    }
    return nil
}

/// Waited for a moment, since a menu opens a turn after it is asked for.
func waitForMenu(_ seconds: Double = 2) -> AXUIElement? {
    let until = Date().addingTimeInterval(seconds)
    repeat {
        if let menu = openMenu() { return menu }
        usleep(50_000)
    } while Date() < until
    return nil
}

func items(of menu: AXUIElement) -> [AXUIElement] {
    children(menu).filter { role($0) == "AXMenuItem" }
}

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

case "button" where arguments.count >= 4:
    var visited = 0
    func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        visited += 1
        guard depth < 40, visited < 20_000 else { return nil }
        if role(element) == "AXButton", title(element) == arguments[3] {
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

case "press" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]) else { exit(1) }
    exit(press(target) ? 0 : 1)

case "open" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]) else { exit(1) }
    // A menu button opens its menu by being pressed. Its "show menu" can be
    // somebody else's: SwiftUI hangs a row's context menu on everything in
    // the row, and asked for that, a chevron in a sidebar row shows the row's.
    let done = role(target) == "AXMenuButton" || !actions(target).contains("AXShowMenu")
        ? press(target)
        : AXUIElementPerformAction(target, "AXShowMenu" as CFString) == .success
    guard done else { exit(1) }
    exit(waitForMenu() == nil ? 1 : 0)

case "items":
    guard let menu = waitForMenu(1) else { exit(1) }
    for item in items(of: menu) {
        let text = title(item) ?? ""
        let enabled = (attribute(item, "AXEnabled") as? Bool) ?? false
        let mark = (attribute(item, "AXMenuItemMarkChar") as? String) ?? ""
        if text.isEmpty && !enabled { print("---"); continue }
        print("\(mark)\t\(enabled ? 1 : 0)\t\(text)")
    }

case "pick" where arguments.count >= 4:
    guard let menu = waitForMenu(1) else { exit(1) }
    let all = items(of: menu)
    let wanted = arguments[3]
    guard let item = all.first(where: { title($0) == wanted })
        ?? all.first(where: { title($0)?.hasPrefix(wanted) == true })
    else { exit(1) }
    exit(press(item) ? 0 : 1)

case "cancel":
    guard let menu = openMenu() else { exit(0) }
    if AXUIElementPerformAction(menu, "AXCancel" as CFString) == .success { exit(0) }
    // Escape, to the app alone, if the menu would not be told.
    let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
    escape?.postToPid(app.processIdentifier)
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(app.processIdentifier)
    exit(0)

case "frame" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]) else { exit(1) }
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(target, "AXPosition") { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(target, "AXSize") { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    print("\(Int(origin.x.rounded())) \(Int(origin.y.rounded())) \(Int(size.width.rounded())) \(Int(size.height.rounded()))")

case "value" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]),
          let value = attribute(target, "AXValue") as? String else { exit(1) }
    print(value)

case "title" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]), let text = title(target) else { exit(1) }
    print(text)

case "menuenabled" where arguments.count >= 5:
    guard let bar = attribute(root, "AXMenuBar") else { exit(1) }
    let barElement = bar as! AXUIElement
    for top in children(barElement) where title(top) == arguments[3] {
        for menu in children(top) {
            for item in children(menu) where title(item) == arguments[4] {
                // No answer is not a no: a question that ran out of time
                // says nothing about the item.
                guard let enabled = attribute(item, "AXEnabled") as? Bool else { exit(1) }
                print(enabled ? 1 : 0)
                exit(0)
            }
        }
    }
    exit(1)

case "enabled" where arguments.count >= 4:
    guard let target = element(labelled: arguments[3]),
          let enabled = attribute(target, "AXEnabled") as? Bool else { exit(1) }
    print(enabled ? 1 : 0)

default:
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}
