import AppKit

/// AppKit at the top; SwiftUI only where it earns its keep (the sidebar).
///
/// Wiring, nothing else: the delegate builds the session, the one window,
/// and the poller, and translates menu items into intents. Every action in
/// the app funnels through `Session.dispatch`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = Session()
    private var controllers: [MainWindowController] = []
    private var poller: DaemonPoller?
    private var claudeModes: ClaudeModeWatcher?
    private let windowStore = WindowStateStore()
    /// Set the moment quitting becomes certain. On the way out AppKit closes
    /// every window, and each of those is indistinguishable — from here —
    /// from somebody closing a window on purpose. Without this the last
    /// thing written down before the app died was "no windows were open",
    /// and it came back with one, every time.
    private var quitting = false
    private var keyMonitor: Any?

    /// ⌘W and ⌘Z do nothing here, with any other modifier held as well.
    ///
    /// A terminal holding work that must not end is the wrong place for a
    /// chord that closes things on a slip of the hand, and ⌘Z has no undo to
    /// offer a shell — only a keystroke for the program to misread. Taken out
    /// before anything sees them — the menus, the sidebar's fields, and the
    /// terminal, where libghostty would otherwise act on them or type them.
    /// Closing stays in the menus and on the tabs' buttons.
    private func swallowUnwantedKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  key == "w" || key == "z"
            else { return event }
            return nil
        }
    }

    /// The window a menu item means.
    ///
    /// Matched by identity rather than trusting `NSWindow.windowController`,
    /// and falling back twice: to the main window, and then to the first one
    /// there is. A modal alert leaves `keyWindow` nil, and a menu item picked
    /// while one is up still has to mean something.
    private var focused: MainWindowController? {
        if let key = NSApp.keyWindow,
           let match = controllers.first(where: { $0.window === key }) { return match }
        if let main = NSApp.mainWindow,
           let match = controllers.first(where: { $0.window === main }) { return match }
        return controllers.first
    }

    /// Every menu action is an intent, and every intent now says where it
    /// came from.
    private func send(_ intent: Intent) {
        guard let controller = focused else { return }
        session.dispatch(intent, from: controller.windowID)
    }

    /// The lowest slot nobody is using.
    ///
    /// Reused rather than always fresh, so a closed window's furniture — its
    /// sidebar, and later its frame — is inherited by the next one opened
    /// instead of accumulating records for windows that are gone.
    private func freeSlot() -> WindowID {
        let taken = Set(controllers.map(\.windowID.slot))
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        return WindowID(slot: slot)
    }

    /// One place that builds a window, so the two callers — somebody asking
    /// for one, and the restore at launch — cannot drift apart.
    private func makeController(id: WindowID) -> MainWindowController {
        let controller = MainWindowController(session: session, id: id)
        controller.onTearOff = { [weak self, weak controller] tab, point, grab in
            guard let self, let controller else { return }
            self.tearOff(tab, at: point, heldAt: grab, from: controller)
        }
        controller.onClose = { [weak self] gone in
            self?.controllers.removeAll { $0 === gone }
            // After the removal: what is written down is what is still open.
            self?.rememberWindows()
        }
        controllers.append(controller)
        return controller
    }

    /// Write down every window that is open, as it is at this moment.
    ///
    /// Called when a window closes and when the app is asked to quit — the
    /// two moments the set changes — rather than on every drag. The frames
    /// are read from the windows themselves, so there is no second copy to
    /// keep in step.
    private func rememberWindows() {
        guard !quitting else { return }
        var records: [Int: WindowRecord] = [:]
        for controller in controllers {
            guard let frame = controller.window?.frame,
                  let placement = session.placement(of: controller.windowID)
            else { continue }
            records[controller.windowID.slot] = WindowRecord(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                workspaces: placement.workspaces,
                tab: placement.tab
            )
        }
        Trace.log("window", "remembered \(records.count)")
        windowStore.save(records)
    }

    /// A tab pulled out of a row and let go.
    ///
    /// Nothing about the session changes: the tab is running, it stays in its
    /// workspace, and it stays in the row it came from. What moves is which
    /// window is looking at it — onto the window it was dropped on, or onto a
    /// new one if it was dropped on nothing — and the row it came from moves
    /// on to a neighbour, because a tab torn out and still showing where it
    /// was is a tab that did not go anywhere.
    private func tearOff(
        _ tab: TabID, at point: NSPoint, heldAt grab: CGFloat, from source: MainWindowController
    ) {
        let over = controller(under: point)
        // Where it landed and what was under it. A tear that went somewhere
        // unexpected has exactly two possible explanations — the drop point
        // or the lookup — and this line is the only place that tells them
        // apart.
        Trace.log(
            "window",
            "dropped at \(Int(point.x)),\(Int(point.y)) over \(over?.windowID.description ?? "nothing")")
        if let target = over, target !== source {
            // `.activateTab` adopts the workspace into that window on the way
            // past, so a window that never carried it still lands on the tab.
            session.dispatch(.activateTab(tab), from: target.windowID)
            target.window?.makeKeyAndOrderFront(nil)
            Trace.log("window", "\(tab) handed to \(target.windowID)")
        } else {
            let controller = makeController(id: freeSlot())
            if let frame = source.window?.frame {
                controller.window?.setFrame(
                    Self.frame(sized: frame.size, forATabDropped: point, heldAt: grab),
                    display: false)
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            session.addWindow(controller.windowID, renderer: controller, carrying: [tab.workspace])
            session.dispatch(.activateTab(tab), from: controller.windowID)
            Trace.log("window", "\(tab) torn into \(controller.windowID)")
        }
        session.dispatch(.showAnotherTab(than: tab), from: source.windowID)
        rememberWindows()
    }

    /// Which of our windows is under a point on screen, if any.
    ///
    /// Asked of the window server rather than of our own frames: windows
    /// overlap, and the one in front is the one somebody aimed at.
    private func controller(under point: NSPoint) -> MainWindowController? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return controllers.first { $0.window?.windowNumber == number }
    }

    /// Where a window torn off at `point` should appear.
    ///
    /// The size of the window it came from — two windows on one tab have to
    /// agree how big it is, and starting them equal makes that agreement a
    /// no-op on the first frame, the same reason ⌘⇧N copies the frame. The
    /// origin puts the row roughly where the hand let go, so the tab appears
    /// under the pointer instead of the window jumping somewhere else.
    private static func frame(
        sized size: NSSize, forATabDropped point: NSPoint, heldAt grab: CGFloat
    ) -> NSRect {
        NSRect(
            x: point.x - grab - chromeAllowance,
            y: point.y - size.height + titlebarAllowance,
            width: size.width,
            height: size.height
        )
    }
    /// Traffic lights and the sidebar toggle, which the row begins after.
    private static let chromeAllowance: CGFloat = 128
    /// Half a titlebar, so the pointer lands on the row rather than above it.
    private static let titlebarAllowance: CGFloat = 19

    /// Open one, on purpose. Along with the restore at launch this is the
    /// only path that makes a window, and it runs when somebody asks for one
    /// — never on a switch, a poll or a render.
    @objc func newWindow(_ sender: Any?) {
        let controller = makeController(id: freeSlot())

        // The same size as the window it was opened from, stepped down and
        // across. Matching the size matters beyond looking tidy: two windows
        // showing one tab have to agree about how big it is, and starting
        // them the same makes that agreement a no-op on the first frame.
        if let from = focused?.window ?? NSApp.keyWindow {
            let frame = from.frame.offsetBy(dx: 24, dy: -24)
            controller.window?.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Empty on purpose: a new window carries no workspaces, and every one
        // there is remains a ⌘P away.
        session.addWindow(controller.windowID, renderer: controller, carrying: [])
        rememberWindows()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = GhosttyApp.shared
        buildMenu()
        swallowUnwantedKeys()

        // Every window this run will have, made here, in one turn of the run
        // loop. A tiling window manager reacts to each window that appears;
        // making them all now costs it one re-tile at launch instead of a
        // series of them as windows trickle in. Slot 0 is always first and
        // always present, and it is the one that brings the session up.
        for id in windowStore.slots {
            let record = windowStore.record(for: id)
            let controller = makeController(id: id)
            if let record {
                controller.place(at: NSRect(
                    x: record.x, y: record.y, width: record.width, height: record.height))
            }
            controller.showWindow(nil)

            if id == .first {
                // Carrying everything only when there is nothing remembered:
                // see `Session.start`.
                session.start(
                    firstWindow: id,
                    renderer: controller,
                    carrying: record?.workspaces,
                    showing: record?.tab
                )
            } else {
                session.addWindow(id, renderer: controller, carrying: record?.workspaces ?? [])
                if let tab = record?.tab { session.dispatch(.activateTab(tab), from: id) }
            }
        }
        controllers.first?.window?.makeKeyAndOrderFront(nil)
        let poller = DaemonPoller(session: session)
        poller.start()
        self.poller = poller
        let claudeModes = ClaudeModeWatcher(session: session)
        claudeModes.start()
        self.claudeModes = claudeModes

        // ⌃` from anywhere: the drop-down terminal. Registered after launch,
        // once — a Carbon hotkey outlives whoever registered it, and two
        // registrations would mean two toggles per press.
        QuickTerminal.shared.registerHotkey()
    }

    /// The app is a viewer; the daemon keeps the work. Closing the window is
    /// quitting — no code path closes daemon tabs on the way out, so quit
    /// trivially leaves everything running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The last chance to look at the windows while they are still open:
    /// by `applicationWillTerminate` there may be nothing left to read.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        rememberWindows()
        quitting = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.flush()
    }

    // MARK: - menu actions (each one is an intent)

    @objc func newTab(_ sender: Any?) { send(.newTab(in: nil)) }
    @objc func goTo(_ sender: Any?) { send(.togglePicker) }
    @objc func palette(_ sender: Any?) { send(.togglePalette(.root)) }
    @objc func find(_ sender: Any?) { send(.toggleSearch(global: false)) }
    @objc func findGlobal(_ sender: Any?) { send(.toggleSearch(global: true)) }
    @objc func closePane(_ sender: Any?) { send(.closePane(nil)) }
    @objc func closeTab(_ sender: Any?) { send(.closeTab(nil)) }
    @objc func splitRight(_ sender: Any?) { send(.split(1)) }
    @objc func splitDown(_ sender: Any?) { send(.split(2)) }
    @objc func nextTab(_ sender: Any?) { send(.nextTab) }
    @objc func previousTab(_ sender: Any?) { send(.previousTab) }
    @objc func nextWorkspace(_ sender: Any?) { send(.nextWorkspace) }
    @objc func previousWorkspace(_ sender: Any?) { send(.previousWorkspace) }

    @objc func showTab(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        send(.activateTabIndex(tag == 9 ? -1 : tag - 1))
    }

    @objc func newWorkspace(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New workspace"
        alert.informativeText = "Workspaces keep running after their windows close."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        // A sheet on the window that asked, rather than `runModal`. An
        // app-modal alert stops every window — including the one the person
        // is watching a build in — and stops the poller with them.
        guard let window = focused?.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.send(.newWorkspace(named: field.stringValue))
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        (focused?.window as? KeepWindow)?.toggleSidebar(sender)
    }

    /// Tabs move into the sidebar, nested under their workspaces, and the
    /// titlebar row steps aside. Per window, like the rest of the furniture.
    @objc func toggleVerticalTabs(_ sender: Any?) { send(.toggleVerticalTabs) }

    @objc func toggleQuickTerminal(_ sender: Any?) { QuickTerminal.shared.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVerticalTabs(_:)) {
            item.state = focused?.isVerticalTabs == true ? .on : .off
        }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Keep", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        // ⌘N stays with New Workspace: a workspace outlives every window that
        // ever showed it, and the primary key belongs to the thing that lasts.
        let newWindowItem = NSMenuItem(
            title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(
            withTitle: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        let splitDownItem = NSMenuItem(
            title: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(splitDownItem)
        fileMenu.addItem(.separator())
        // No keys: closing is a click, never a chord. See `swallowUnwantedKeys`.
        fileMenu.addItem(
            withTitle: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "")
        fileMenu.addItem(
            withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "")
        // AppKit's own, so the routing to the key window is the system's and
        // not ours to get wrong.
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // The standard editing commands, routed through the responder chain
        // to whichever terminal has focus. Without this menu, copy and paste
        // depended entirely on libghostty's own key table seeing the event —
        // a menu key equivalent is checked before the window and is the one
        // path a Mac user can count on.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Go To…", action: #selector(goTo(_:)), keyEquivalent: "p")
        // The same overlay, the other question: what can be done rather than
        // where to go. ⇧ of the key that asks the first one.
        let paletteItem = goMenu.addItem(
            withTitle: "Commands…", action: #selector(palette(_:)), keyEquivalent: "p")
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(
            withTitle: "Find in Pane…", action: #selector(find(_:)), keyEquivalent: "f")
        let findAllItem = NSMenuItem(
            title: "Find Everywhere…", action: #selector(findGlobal(_:)), keyEquivalent: "f")
        findAllItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(findAllItem)
        goItem.submenu = goMenu
        main.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = viewMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)), keyEquivalent: "b")
        toggleSidebarItem.target = self
        let verticalTabsItem = viewMenu.addItem(
            withTitle: "Vertical Tabs",
            action: #selector(toggleVerticalTabs(_:)), keyEquivalent: "")
        verticalTabsItem.target = self
        // In the menu for discoverability; the hotkey itself is global and
        // works with the app in the background, which a key equivalent
        // cannot.
        let quickItem = viewMenu.addItem(
            withTitle: "Quick Terminal",
            action: #selector(toggleQuickTerminal(_:)), keyEquivalent: "`")
        quickItem.keyEquivalentModifierMask = [.control]
        quickItem.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let nextItem = NSMenuItem(
            title: "Show Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "\t")
        nextItem.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(nextItem)
        let previousItem = NSMenuItem(
            title: "Show Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "\t")
        previousItem.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(previousItem)
        windowMenu.addItem(.separator())
        // A step out from ⌃Tab, because ⌃Tab is already the tabs' and a menu
        // key equivalent is matched before anything else can answer for it —
        // a second one here would simply never win.
        let nextSpaceItem = NSMenuItem(
            title: "Show Next Workspace",
            action: #selector(nextWorkspace(_:)),
            keyEquivalent: "\t")
        nextSpaceItem.keyEquivalentModifierMask = [.control, .option]
        windowMenu.addItem(nextSpaceItem)
        let previousSpaceItem = NSMenuItem(
            title: "Show Previous Workspace",
            action: #selector(previousWorkspace(_:)),
            keyEquivalent: "\t")
        previousSpaceItem.keyEquivalentModifierMask = [.control, .option, .shift]
        windowMenu.addItem(previousSpaceItem)
        windowMenu.addItem(.separator())
        // ⌘1–⌘8 select by position; ⌘9 is the last tab, per macOS convention.
        for n in 1...9 {
            let item = NSMenuItem(
                title: n == 9 ? "Show Last Tab" : "Show Tab \(n)",
                action: #selector(showTab(_:)),
                keyEquivalent: String(n))
            item.tag = n
            windowMenu.addItem(item)
        }
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

// Top-level code runs on the main actor when the entry point awaits it.
MainActor.assumeIsolated {
    // A terminal view that composes text is, to macOS, a text view, and
    // holding a key down in one opens the accent picker instead of repeating
    // the key — hjkl in an editor would stop after one step. Ghostty turns the
    // picker off for the same reason; accents still come from dead keys.
    UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    // Keep the delegate alive for the app's lifetime.
    objc_setAssociatedObject(app, "keep.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
