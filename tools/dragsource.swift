// Something to drag from: a small window that, pressed and pulled, starts a
// drag carrying what it was told to carry — files as Finder carries them,
// text as the sidebar carries its rows, or a file promised the way Mail
// carries an attachment.
//
//   dragsource <x> <y> files <path>...
//   dragsource <x> <y> text <string>
//   dragsource <x> <y> promise <file name> <contents>
//
// x and y are where the window's middle goes, in the screen's top-left space:
// the one CGEvent and tools/mousedrag.swift use, so a test can aim at it.
// Prints "ready" once the window is on screen, then "ended copy" or
// "ended none" when the drag is let go, and exits a few seconds later — long
// enough for whoever took a promise to have the file written.
//
// Written for tools/drop-test.sh. The drag has to be a real one, begun by a
// real press and routed by the window server: what is under test is whether
// the terminal is the view AppKit hands the drop to, and a drop handed to it
// by the test would skip exactly that.
import Cocoa
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("""
        usage: dragsource <x> <y> files <path>...
               dragsource <x> <y> text <string>
               dragsource <x> <y> promise <file name> <contents>

        """.utf8))
    exit(2)
}
let kind = args[3]
let rest = Array(args.dropFirst(4))

final class Source: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private var started = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        let items = payload().map { writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: nil)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    private func payload() -> [NSPasteboardWriting] {
        switch kind {
        case "files":
            return rest.map { URL(fileURLWithPath: $0) as NSURL }
        case "text":
            return [(rest.first ?? "") as NSString]
        case "promise":
            return [NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: self)]
        default:
            return []
        }
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        print(operation.isEmpty ? "ended none" : "ended copy")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String { rest.first ?? "promised.txt" }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try (rest.count > 1 ? rest[1] : "").write(to: url, atomically: true, encoding: .utf8)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let side: CGFloat = 120
let screenHeight = NSScreen.screens.first?.frame.height ?? 900
let window = NSWindow(
    contentRect: NSRect(
        x: x - side / 2, y: screenHeight - y - side / 2, width: side, height: side),
    styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating
window.contentView = Source(frame: NSRect(x: 0, y: 0, width: side, height: side))
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    print("ready")
    fflush(stdout)
}
// Nobody lets go within a minute: the test has gone wrong, and this must not
// be left on the screen.
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
app.run()
