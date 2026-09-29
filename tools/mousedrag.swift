// A drag the system treats as real, and the window server's idea of where a
// window is.
//
//   mousedrag frame                                  -> "x y w h" for Keep's window
//   mousedrag windows                                -> one "id x y w h" per window
//   mousedrag watch <seconds>                        -> a line per position it takes
//   mousedrag move <x> <y>                           -> park the pointer, press nothing
//   mousedrag click <x> <y>                          -> walk there and click once
//   mousedrag drag <x1> <y1> <x2> <y2> <steps> <ms>
//
// Separate from sendkey, and posting to the HID tap rather than to the app's
// pid, for a reason the tab strip paid for: a pid-posted event skips the
// window server, so the drag a window server runs for a press in a titlebar
// never starts, and a test built on one cannot see the bug where a window
// walking off with the pointer eats a tab's drag. It moves the real cursor,
// which is the cost of asking the real question.
//
// Coordinates are the screen's, top-left origin — the space CGEvent uses and
// the space CGWindowList answers in, which is why the frame is asked of the
// window server and not of the accessibility API: under a tiling window
// manager the two disagree, and aiming with the wrong one clicks the desktop.
import Cocoa

let args = CommandLine.arguments

/// Which app's windows these commands are about.
///
/// Not always "Keep": the suites drive a build of their own, named apart, so
/// that they can be run while somebody is working in the real one. Counting
/// or dragging the wrong app's window is the failure this exists to stop.
let appName = ProcessInfo.processInfo.environment["KEEP_APP_NAME"] ?? "Keep"

func keepFrame() -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for info in list {
        guard (info[kCGWindowOwnerName as String] as? String) == appName,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let height = bounds["Height"] as? Double, height > 200,
              let width = bounds["Width"] as? Double,
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double
        else { continue }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    return nil
}

let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

switch args.count > 1 ? args[1] : "" {
case "id":
    // The window server's own handle for the window, so a screenshot can name
    // it instead of describing a rectangle. On a display whose origin is
    // negative, a rectangle is the less reliable of the two.
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { exit(1) }
    for info in list {
        guard (info[kCGWindowOwnerName as String] as? String) == appName,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let height = bounds["Height"] as? Double, height > 200,
              let id = info[kCGWindowNumber as String] as? Int
        else { continue }
        print(id)
        exit(0)
    }
    exit(1)

case "windows":
    // Every window Keep has on screen, so a test can count them and watch
    // each one separately. The window server's list is the only account that
    // does not depend on the app agreeing about what it has.
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { exit(1) }
    for info in list {
        guard (info[kCGWindowOwnerName as String] as? String) == appName,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let height = bounds["Height"] as? Double, height > 200,
              let width = bounds["Width"] as? Double,
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let id = info[kCGWindowNumber as String] as? Int
        else { continue }
        print("\(id) \(Int(x)) \(Int(y)) \(Int(width)) \(Int(height))")
    }

case "frame":
    guard let frame = keepFrame() else {
        FileHandle.standardError.write(Data("no Keep window on screen\n".utf8))
        exit(1)
    }
    print("\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))")

case "watch":
    guard args.count >= 3, let seconds = Double(args[2]) else { exit(2) }
    let end = Date().addingTimeInterval(seconds)
    var last = ""
    while Date() < end {
        if let frame = keepFrame() {
            let now = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            if now != last {
                print("\(clock.string(from: Date()))  window \(now)")
                last = now
            }
        }
        usleep(8000)
    }

case "move":
    // A hover is not a click, and anything that looks at hovering has to be
    // able to be shown a pointer that is merely present.
    //
    // Walked there rather than put there. A single event teleports the cursor
    // and the tracking machinery does not reconsider what is under it, so a
    // view waiting to be hovered is never told — which reads, from outside,
    // exactly like a hover effect that was never written. A hand approaches.
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
    let source = CGEventSource(stateID: .hidSystemState)
    let from = CGEvent(source: nil)?.location ?? CGPoint(x: x, y: y)
    for step in 1...12 {
        let t = Double(step) / 12
        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(
                x: from.x + (x - from.x) * t, y: from.y + (y - from.y) * t),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(12_000)
    }

case "click":
    // One click, as a hand makes it: walked there, a pause for the view
    // under the pointer to have been told it is there, then down and up.
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
    let source = CGEventSource(stateID: .hidSystemState)
    let target = CGPoint(x: x, y: y)
    let from = CGEvent(source: nil)?.location ?? target
    for step in 1...12 {
        let t = Double(step) / 12
        let event = CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(
                x: from.x + (x - from.x) * t, y: from.y + (y - from.y) * t),
            mouseButton: .left)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
    usleep(150_000)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
            mouseButton: .left)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
        usleep(60_000)
    }

case "drag":
    guard args.count >= 8,
        let x1 = Double(args[2]), let y1 = Double(args[3]),
        let x2 = Double(args[4]), let y2 = Double(args[5]),
        let steps = Int(args[6]), steps > 0, let ms = Double(args[7])
    else { exit(2) }
    let source = CGEventSource(stateID: .hidSystemState)
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left)
        // Cleared, always: an event inherits whatever the system believes is
        // held, and a stray modifier makes a drag mean something else.
        event?.flags = []
        event?.post(tap: .cghidEventTap)
        usleep(UInt32(ms * 1000))
    }
    // A move first, and a pause after it. A window decides in advance whether
    // it may be dragged by the region under the pointer, so a press with no
    // approach is a press the app was never given the chance to answer for —
    // and a person's hand always approaches.
    mouse(.mouseMoved, CGPoint(x: x1, y: y1))
    usleep(150_000)
    mouse(.leftMouseDown, CGPoint(x: x1, y: y1))
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
    }
    mouse(.leftMouseUp, CGPoint(x: x2, y: y2))

default:
    FileHandle.standardError.write(Data("""
        usage: mousedrag id
               mousedrag windows
               mousedrag frame
               mousedrag watch <seconds>
               mousedrag move <x> <y>
               mousedrag click <x> <y>
               mousedrag drag <x1> <y1> <x2> <y2> <steps> <ms>

        """.utf8))
    exit(2)
}
