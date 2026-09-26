// What an app's windows say, read through the accessibility tree.
//
// One line per element that carries text — its value, title or description —
// in the order the tree lists them, which for the sidebar is top to bottom:
// a workspace's header, then its tabs. Menus are left out; only windows are
// walked, each after a line "=== window <x>" giving its left edge in points,
// so a test with two windows can tell whose sidebar is whose.
//
//   axtext <app name>
//
// Written for tools/restore-test.sh, which has to know what the sidebar shows
// rather than what the app believes it shows: the defect it guards against was
// an app whose model held every workspace and whose window listed one.
import AppKit
import ApplicationServices

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: axtext <app name>\n".data(using: .utf8)!)
    exit(2)
}
let name = CommandLine.arguments[1]
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })
else {
    FileHandle.standardError.write("axtext: \(name) is not running\n".data(using: .utf8)!)
    exit(1)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("axtext: not trusted for accessibility\n".data(using: .utf8)!)
    exit(3)
}

func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

var visited = 0
func walk(_ element: AXUIElement, depth: Int) {
    visited += 1
    guard depth < 60, visited < 50_000 else { return }
    for key in ["AXValue", "AXTitle", "AXDescription"] {
        if let text = attribute(element, key) as? String, !text.isEmpty { print(text) }
    }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
        walk(child, depth: depth + 1)
    }
}

let root = AXUIElementCreateApplication(app.processIdentifier)
for window in attribute(root, "AXWindows") as? [AXUIElement] ?? [] {
    var origin = CGPoint.zero
    if let value = attribute(window, "AXPosition") {
        AXValueGetValue(value as! AXValue, .cgPoint, &origin)
    }
    print("=== window \(Int(origin.x))")
    walk(window, depth: 0)
}
