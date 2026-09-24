import AppKit

/// THE window, alive for the app's lifetime.
///
/// Layer 6's root: it receives immutable snapshots from the session and
/// drives exactly four things — the tab strip, the content container, the
/// sidebar, and the window title. It dispatches intents and mutates no model
/// state. No window is ever created, closed, ordered, animated, or resized
/// by a switch; that sentence is the fix for every transition bug this app
/// ever had.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let session: Session
    private let tabStrip = TabStripView()
    private let container = TabContentContainer()
    private let sidebarHost: SidebarHost
    private let picker = PickerView()
    private weak var sidebarItem: NSSplitViewItem?
    private weak var splitView: NSSplitView?

    private var applied: SessionSnapshot?
    /// The tab a carried pane is hovering over, and the wait before it opens.
    private var springTarget: TabID?
    private var spring: Timer?
    /// True while render is moving geometry, so the split-view delegate does
    /// not echo model-driven changes back as user intents.
    private var isApplyingSnapshot = false
    private var dividerReportScheduled = false
    private var lastExpandedWidth: CGFloat = SidebarState.initial.width
    /// Whether the remembered width has been put on a split view that had a
    /// size to put it on.
    private var hasPlacedDivider = false

    /// Which window this is, for the model. Everything below the UI knows a
    /// window only by this — never by an `NSWindow`.
    let windowID: WindowID

    /// Every intent this window sends carries its own name.
    private func send(_ intent: Intent) { session.dispatch(intent, from: windowID) }

    /// Told when this window has gone, so the delegate can let the controller
    /// go with it.
    var onClose: ((MainWindowController) -> Void)?
    /// A tab was pulled out of this window's row and let go: the tab, where
    /// it landed on screen, and how far along the cell it was held.
    ///
    /// Answered by the delegate, not here. Making a window is the one thing
    /// this controller deliberately cannot do — see the rule at the top of
    /// ARCHITECTURE.md — and a controller that could make its own would be
    /// the pool that grew and shrank all over again.
    var onTearOff: ((TabID, NSPoint, CGFloat) -> Void)?

    /// For the menu's checkmark: whether this window keeps its tabs in the
    /// sidebar. Read from the applied snapshot — the one account that is
    /// already true on screen.
    var isVerticalTabs: Bool { applied?.sidebar.verticalTabs ?? false }

    init(session: Session, id: WindowID) {
        self.session = session
        self.windowID = id
        container.windowID = id
        sidebarHost = SidebarHost(dispatch: { [weak session] in session?.dispatch($0, from: id) })

        // The window's content extends under the titlebar (fullSizeContentView,
        // which the full-height sidebar needs), so the terminal container hangs
        // off the safe area or its first rows render behind the chrome row.
        let content = NSView()
        let chromeBackdrop = TerminalTintBackdropView()
        chromeBackdrop.wantsLayer = true
        chromeBackdrop.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chromeBackdrop)
        content.addSubview(container)
        // The strip lives in the chrome row — the same region the backdrop
        // tints, above the terminal, beside the sidebar. Plain content: no
        // toolbar sizing, no private views, and empty regions still drag the
        // window because the strip's hitTest passes them through.
        content.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            chromeBackdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeBackdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chromeBackdrop.topAnchor.constraint(equalTo: content.topAnchor),
            chromeBackdrop.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let terminal = NSViewController()
        terminal.view = content

        let split = NSSplitViewController()
        split.splitView = SeamlessSplitView()
        split.splitView.isVertical = true
        let sidebarSplitItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarSplitItem.minimumThickness = 200
        sidebarSplitItem.maximumThickness = 320
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.canCollapseFromWindowResize = false
        sidebarSplitItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Just above the terminal item's 250, and deliberately not
        // `.defaultHigh`. Holding priority is the priority of the constraint
        // that keeps this item's thickness, so it decides two things at once:
        // who absorbs a window resize, and whether anything else may set the
        // width. At 500 the sidebar held its thickness against `setPosition`
        // too, and every remembered width was silently discarded — the
        // sidebar came up at its minimum every launch and looked like it had
        // simply been left there. At 260 the terminal still absorbs the
        // window, measured at 1400 and 900 wide, and the width can be placed.
        sidebarSplitItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        split.addSplitViewItem(sidebarSplitItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminal))

        let window = KeepWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        // Native tabbing is gone for good; switching is a visibility flip.
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        // Restoration otherwise reopens at whatever size a previous run left.
        window.isRestorable = false
        window.setFrame(NSRect(x: 0, y: 0, width: 1040, height: 660), display: false)
        window.center()

        window.installUnifiedToolbar(
            chromeBackdrop: chromeBackdrop,
            sidebarBackdrop: sidebarHost.backdropView
        )

        self.sidebarItem = sidebarSplitItem
        self.splitView = split.splitView

        super.init(window: window)
        window.delegate = self

        window.onToggleSidebar = { [weak self] in
            guard let self, let state = self.currentSidebarGeometry() else { return }
            self.send(.setSidebar(
                SidebarState(isCollapsed: !state.isCollapsed, width: state.width)))
        }
        container.onPaneTitle = { [weak self] id, pane, title in
            self?.send(.notePaneTitle(id, pane, title))
        }
        container.onPaneFocus = { [weak self] id, pane in
            self?.send(.focusPane(id, pane))
        }
        // A pane carried over a tab opens it, after long enough to mean it.
        // The timer runs in the event-tracking mode too: during a drag that
        // is the only mode there is, and a timer that only fires in the
        // default mode never fires at all.
        container.tabUnderPointer = { [weak self] windowPoint in
            guard let self else { return nil }
            return self.tabStrip.tab(at: self.tabStrip.convert(windowPoint, from: nil))
        }
        container.onCarryOver = { [weak self] windowPoint in
            guard let self else { return }
            guard let windowPoint else {
                self.cancelSpring()
                return
            }
            let over = self.tabStrip.tab(at: self.tabStrip.convert(windowPoint, from: nil))
            guard let over, over != self.container.visibleTab else {
                self.cancelSpring()
                return
            }
            guard over != self.springTarget else { return }
            self.cancelSpring()
            self.springTarget = over
            let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let target = self.springTarget else { return }
                    self.send(.activateTab(target))
                }
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.add(timer, forMode: .eventTracking)
            self.spring = timer
        }
        // The tab a pane was picked up from, not the one on screen: carrying
        // it over another tab opens that one, so by the time it is let go the
        // source is no longer active. Only the workspace has to match — the
        // model checks that the panes are really there.
        container.onPaneDrop = { [weak self] id, pane, target, side in
            guard let self, id.workspace == self.applied?.active?.id.workspace else { return }
            Trace.log("carry", "drop \(pane) onto \(target) \(side)")
            self.send(.movePane(pane, to: target, side: side))
        }
        container.onPaneDetach = { [weak self] id, pane in
            guard let self, id.workspace == self.applied?.active?.id.workspace else { return }
            Trace.log("carry", "detach \(pane)")
            self.send(.detachPane(pane))
        }
        tabStrip.onSelect = { [weak self] id in self?.send(.activateTab(id)) }
        tabStrip.onClose = { [weak self] id in self?.send(.closeTab(id)) }
        tabStrip.onRename = { [weak self] id, name in self?.renamed(id, to: name) }
        tabStrip.onGoTo = { [weak self] in self?.send(.togglePicker) }
        tabStrip.onCommands = { [weak self] in self?.send(.togglePalette(.root)) }
        tabStrip.onReorder = { [weak self] ids in self?.send(.reorderTabs(ids, in: nil)) }
        tabStrip.onTearOff = { [weak self] id, point, grab in
            self?.onTearOff?(id, point, grab)
        }
        // The row's leading edge is the sidebar's trailing edge, and the
        // toggle above the sidebar rides it.
        tabStrip.onLeadingEdgeMoved = { [weak self] edge in
            (self?.window as? KeepWindow)?.trackSidebarEdge(edge)
        }

        picker.onHighlight = { [weak self] id in
            self?.send(.previewPickerItem(id))
        }
        picker.onChoose = { [weak self] id in self?.choose(id) }
        picker.onBack = { [weak self] in self?.send(.togglePalette(.root)) }
        picker.onDismissItem = { [weak self] id in
            self?.send(.dismissPickerItem(id))
        }
        picker.onAction = { [weak self] id, action in self?.run(action, on: id) }
        picker.onCancel = { [weak self] in self?.send(.closePicker) }
        picker.onFilter = { [weak self] query in
            self?.send(.setPickerQuery(query))
        }

        // Divider drags become model facts, debounced; model-driven geometry
        // is guarded out so it cannot echo back as intent.
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split.splitView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dividerMoved() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - SessionRendering

    func render(_ snapshot: SessionSnapshot) {
        // Tabs the daemon lost take their hosts with them.
        for id in container.hosts.keys where !snapshot.universe.contains(id) {
            container.unmount(id)
        }

        sidebarHost.render(snapshot.rows)
        tabStrip.apply(snapshot.strip)
        renderPicker(snapshot.picker)
        // The sidebar is one state for the whole app: applied here, once,
        // rather than restored per tab. The user's own toggle animates.
        if applied?.sidebar != snapshot.sidebar {
            applySidebar(snapshot.sidebar, animated: applied != nil)
        }
        // Vertical tabs: the titlebar row steps aside. The strip keeps the
        // window still while the pointer is over a tab, so leaving with it
        // hidden would leave the window immovable — hand the window back.
        if tabStrip.isHidden != snapshot.sidebar.verticalTabs {
            tabStrip.isHidden = snapshot.sidebar.verticalTabs
            if snapshot.sidebar.verticalTabs { window?.isMovable = true }
        }

        guard let active = snapshot.active else {
            if let visible = container.visibleTab {
                container.hide(visible)
                container.markVisible(TabID(workspace: "", root: 0))
            }
            applied = snapshot
            return
        }

        if active.id != container.visibleTab {
            switchVisible(to: active)
        } else {
            // Same tab: apply what changed around it.
            let host = container.host(for: active)
            let rebuilt = host.apply(root: active.id.root, panes: active.panes)
            host.setFocusedPane(active.focusedPane)
            // Re-assert the keyboard when the focus moved OR when the
            // arrangement was rebuilt: a rebuild severs the responder chain,
            // and leaving it where AppKit dropped it can put keystrokes into
            // a surface belonging to a tab nobody is looking at.
            if rebuilt || applied?.active?.focusedPane != active.focusedPane,
                let surface = host.surface(for: active.focusedPane),
                window?.firstResponder !== surface
            {
                window?.makeFirstResponder(surface)
            }
            updateTitle(active)
        }
        applied = snapshot
    }

    func focusActiveTerminal() {
        guard let id = container.visibleTab,
              let host = container.hosts[id],
              let pane = applied?.active?.focusedPane,
              let surface = host.surface(for: pane) ?? host.paneSurfaces.first,
              window?.firstResponder !== surface
        else { return }
        window?.makeFirstResponder(surface)
    }

    /// A name typed over a tab in the row, or nothing typed and the keyboard
    /// to hand back.
    ///
    /// The session puts the keyboard on the terminal after a rename, which is
    /// where Return means it to go. It is wrong wherever the name was left
    /// for another field: the picker, opened with ⌘P halfway through typing
    /// it, or a field in the sidebar that a click went into. Either one has
    /// the keyboard by the time the name arrives here, and a keyboard sent
    /// past it types into a shell nobody is looking at — the Return meant to
    /// finish the other field included, which runs whatever was typed. So
    /// the field that had it takes it back, with its caret where it was.
    private func renamed(_ id: TabID, to name: String?) {
        guard let name else {
            focusActiveTerminal()
            return
        }
        // Asked before the session moves it. The field editor is shared,
        // so the field is its delegate, and the caret is the editor's.
        let editor = (window?.firstResponder as? NSTextView).flatMap {
            $0.isFieldEditor ? $0 : nil
        }
        let field = editor?.delegate as? NSView
        let selection = editor?.selectedRanges
        send(.renameTab(id, to: name))
        if picker.superview != nil, !picker.isHidden {
            picker.takeFocus()
        } else if let field, field.window === window, !field.isDescendant(of: tabStrip),
                  window?.firstResponder !== editor,
                  window?.makeFirstResponder(field) == true,
                  let selection,
                  let restored = window?.firstResponder as? NSTextView, restored.isFieldEditor {
            restored.selectedRanges = selection
        }
    }

    /// The picker covers the whole window while it is up, and takes the
    /// keyboard for exactly that long.
    private func renderPicker(_ model: PickerModel?) {
        guard let model else {
            guard picker.superview != nil, !picker.isHidden else { return }
            // Hidden, not removed. Taking a view out of a window frees every
            // layer under it and re-adding it builds them again — a card, a
            // material, a table of rows and whatever glass they carry — for
            // an overlay whose whole life is a keystroke long. Hidden it
            // takes no events and draws nothing, and the second ⌘P is free.
            picker.isHidden = true
            (window as? KeepWindow)?.holdOpaque(false)
            // Removing a view takes the keyboard off whatever inside it was
            // holding it; hiding one does not. Hand it back deliberately, or
            // the overlay is gone and every keystroke still goes to its
            // field editor.
            if let holder = window?.firstResponder as? NSView,
               holder.isDescendant(of: picker) {
                focusActiveTerminal()
            }
            return
        }
        if picker.superview == nil, let content = window?.contentView {
            picker.frame = content.bounds
            picker.autoresizingMask = [.width, .height]
            picker.isHidden = true
            content.addSubview(picker)
        }
        if picker.isHidden {
            Trace.log("picker", "opening")
            // Where our own clock stops being the answer. Everything below
            // is a few milliseconds of main thread; what is left is the
            // window server building the layers and painting them, and the
            // only way to see that from in here is to ask when the
            // transaction carrying it actually commits.
            CATransaction.begin()
            // Nothing here is a state change worth watching happen. Every
            // layer property touched on the way in — a view unhiding, a
            // plate taking the theme's colour, a rim laying itself out —
            // animates implicitly over a quarter of a second unless it is
            // told not to, and a quarter of a second is exactly what "not
            // instant" feels like. The overlay is meant to be *there*.
            CATransaction.setDisableActions(true)
            // The one number that mattered, and the one our own clock could
            // not give: everything above is a few milliseconds of main
            // thread, and what was left was a quarter of a second of implicit
            // animation. Kept, because the next thing to slow this down will
            // not be visible any other way either.
            if Trace.enabled {
                let asked = DispatchTime.now().uptimeNanoseconds
                CATransaction.setCompletionBlock {
                    let spent = Double(
                        DispatchTime.now().uptimeNanoseconds - asked) / 1_000_000
                    Trace.log("picker", "on screen \(String(format: "%.1f", spent))ms")
                }
            }
            defer {
                Trace.log("picker", "open")
                CATransaction.commit()
            }
            // The card's blur samples this window, and where this window is
            // see-through what it samples is the desktop. Opaque for as long
            // as the overlay is up, so the blur has nothing but terminal in
            // it — which is what lets the card be as thin as it is.
            Trace.time("picker", "holdOpaque") {
                (window as? KeepWindow)?.holdOpaque(true)
            }
            Trace.time("picker", "show") { picker.isHidden = false }
            // Opened, so it opens empty — see `prepareForOpen`.
            Trace.time("picker", "prepare") { picker.prepareForOpen() }
            Trace.time("picker", "apply") { picker.apply(model) }
            Trace.time("picker", "focus") { picker.takeFocus() }
            return
        }
        picker.apply(model)
    }

    /// A chosen row, sorted by who can carry it out.
    ///
    /// Going somewhere is the session's business and goes down the one
    /// channel. Running a command and wearing a theme are not: a window is
    /// opened by AppKit, a theme by libghostty, and neither is state the
    /// session holds. Those are done here, and only the closing of the
    /// overlay travels back through the model.
    private func choose(_ id: String) {
        guard let item = applied?.picker?.items.first(where: { $0.id == id }) else {
            send(.choosePickerItem(id))
            return
        }
        switch item.kind {
        case .command(let command):
            run(command)
        case .theme(let name):
            wear { $0.theme = name }
        case .fontFamily(let name):
            wear { $0.fontFamily = name }
        case .running, .destination, .hit:
            send(.choosePickerItem(id))
        }
    }

    /// Change the terminal's appearance and put the overlay away.
    ///
    /// The overlay first: adopting a config repaints every surface in the
    /// app, and doing that underneath an open picker means the repaint and
    /// the dismissal land in different frames.
    private func wear(_ change: (inout TerminalPrefs) -> Void) {
        send(.closePicker)
        var prefs = GhosttyApp.prefs
        change(&prefs)
        GhosttyApp.shared.adopt(prefs)
    }

    /// One of the palette's commands.
    private func run(_ command: Command) {
        // A command that opens a list is not a command that finishes: the
        // overlay stays up and changes what it is asking.
        if let catalog = command.opens {
            send(.togglePalette(catalog))
            return
        }
        send(.closePicker)
        switch command {
        case .toggleSidebar:
            (window as? KeepWindow)?.toggleSidebar(nil)
        case .toggleVerticalTabs:
            send(.toggleVerticalTabs)
        case .splitRight:
            send(.split(1))
        case .splitDown:
            send(.split(2))
        case .closePane:
            send(.closePane(nil))
        case .closeTab:
            send(.closeTab(nil))
        case .newTab:
            send(.newTab(in: nil))
        case .newWindow:
            // Through the responder chain, because a window is opened by the
            // app delegate and this controller is one of its windows.
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        case .newWorkspace:
            // Same, and for the same reason: naming it is a sheet.
            NSApp.sendAction(Selector(("newWorkspace:")), to: nil, from: nil)
        case .removeWorkspace:
            guard let name = applied?.active?.id.workspace else { return }
            send(.removeWorkspace(name))
        case .killWorkspace:
            guard let name = applied?.active?.id.workspace else { return }
            send(.killWorkspace(name))
        case .fontBigger:
            wear { $0.fontSize = min(Self.step(GhosttyApp.shared.terminalFontSize, by: 1), 32) }
        case .fontSmaller:
            wear { $0.fontSize = max(Self.step(GhosttyApp.shared.terminalFontSize, by: -1), 8) }
        case .fontReset:
            wear { $0.fontSize = nil; $0.fontFamily = nil }
        case .clearTheme:
            wear { $0.theme = nil }
        case .chooseTheme, .chooseFont:
            break
        }
    }

    private static func step(_ size: Double, by amount: Double) -> Double {
        (size + amount).rounded()
    }

    /// What the picker's actions panel asked for, on the row it was over.
    ///
    /// Two kinds of thing, kept apart on purpose. Going somewhere and closing
    /// something are facts about the session, so they go down the one channel
    /// as intents. Revealing a folder and copying a path change nothing here
    /// — they hand a string to another program — so they are done on the spot
    /// rather than travelling through the model to come back out unchanged.
    private func run(_ action: PickerAction, on id: String) {
        guard let item = applied?.picker?.items.first(where: { $0.id == id }) else { return }
        switch action {
        case .open:
            send(.choosePickerItem(id))
        case .close:
            send(.dismissPickerItem(id))
        case .newTab:
            send(.closePicker)
            send(.newTab(in: item.workspace.isEmpty ? nil : item.workspace))
        case .reveal:
            guard !item.path.isEmpty else { return }
            send(.closePicker)
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: item.path)])
        case .copyPath:
            put(item.path, onTheBoard: "path")
            send(.closePicker)
        case .copyText:
            put(item.title, onTheBoard: "line")
            send(.closePicker)
        }
    }

    private func put(_ text: String, onTheBoard what: String) {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        Trace.log("picker", "copied \(what)")
    }

    func present(error: String) {
        let alert = NSAlert()
        alert.messageText = "Keep"
        alert.informativeText = error
        // On this window, and only this one. `runModal` would freeze the
        // others and hold the run loop, which stops the poller reconciling
        // and leaves every window's idea of the daemon ageing.
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - the switch pipeline

    /// One synchronous pass, one run-loop turn, no dispatch hops. Everything
    /// commits in a single CoreAnimation transaction, so no composited frame
    /// can show an intermediate state.
    private func switchVisible(to active: SessionSnapshot.ActiveTab) {
        Trace.insideSwitch = true
        defer { Trace.insideSwitch = false }
        Trace.log("switch", "→ \(active.id) from=\(container.visibleTab.map(String.init(describing:)) ?? "none")")

        let previous = container.visibleTab
        let incoming = container.host(for: active)
        let outgoing = previous.flatMap { container.hosts[$0] }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 2. Arrangement and layout while still hidden (hidden views lay out
        //    fine; surface sizes flush on unhide).
        incoming.apply(root: active.id.root, panes: active.panes)
        incoming.setFocusedPane(active.focusedPane)
        incoming.frame = container.bounds
        incoming.layoutSubtreeIfNeeded()

        // 3. Reveal. Unhiding runs `viewDidUnhide` on every pane synchronously,
        //    inside this transaction: each flushes the size it deferred while
        //    hidden and draws one frame at final geometry. So the fresh frame
        //    lands before the commit, and at worst the layer still held its
        //    last presented one — either way, never a hole.
        incoming.isHidden = false

        // 4. Hide the outgoing LAST, in the same transaction: no commit ever
        //    has zero visible tabs. Its display links stop from viewDidHide.
        if let outgoing, outgoing !== incoming {
            outgoing.isHidden = true
        }

        CATransaction.commit()

        // 5. Focus: an intra-window responder move. The one window has been
        //    key since launch and never resigns; there is nothing here for
        //    the system, or a tiling window manager, to react to.
        if let surface = incoming.surface(for: active.focusedPane) {
            window?.makeFirstResponder(surface)
        }

        container.markVisible(active.id)
        updateTitle(active)
    }

    // MARK: - sidebar geometry

    /// A collapsed sidebar has no width to read, and reading zero — then
    /// substituting a default — would overwrite the width the tab actually
    /// remembers. The last real expanded width is the only honest answer
    /// while collapsed.
    private func currentSidebarGeometry() -> SidebarState? {
        guard let sidebarItem else { return nil }
        let width = sidebarItem.viewController.view.frame.width
        if !sidebarItem.isCollapsed && width > 1 { lastExpandedWidth = width }
        return SidebarState(isCollapsed: sidebarItem.isCollapsed, width: lastExpandedWidth)
    }

    private func applySidebar(_ state: SidebarState, animated: Bool) {
        guard let sidebarItem, let splitView else { return }
        let current = currentSidebarGeometry()
        guard current != state else { return }
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                // Short, because every frame of it costs: the terminal is
                // re-laid out and the shell is told its new size at each one.
                context.duration = 0.12
                sidebarItem.animator().isCollapsed = state.isCollapsed
            }
        } else {
            sidebarItem.isCollapsed = state.isCollapsed
        }
        // Coming back from collapsed counts as needing the width placed even
        // when the remembered one has not changed: the split view reopens at
        // its own natural size, and without this the sidebar reappears at its
        // minimum and that minimum is then saved as though it were a choice.
        let reopening = current?.isCollapsed == true && !state.isCollapsed
        if !state.isCollapsed, reopening || current?.width != state.width || !hasPlacedDivider {
            lastExpandedWidth = state.width
            splitView.setPosition(state.width, ofDividerAt: 0)
            hasPlacedDivider = splitView.bounds.width > 1
            Trace.log(
                "sidebar",
                "width \(Int(state.width)) → \(Int(sidebarItem.viewController.view.frame.width))")
        }
        // Nothing is said to the strip about the chrome it has to clear. It
        // can see where it starts, and while the sidebar is animating that is
        // the only account of the matter that is true at every frame.
    }

    /// Put the window back where it was.
    ///
    /// Only if that is still somewhere it can be seen: a frame remembered on
    /// a second monitor, restored on a laptop that no longer has one, puts
    /// the window off the edge of everything — visible in Mission Control and
    /// nowhere else. When the screen it wants is gone it keeps the centred
    /// default it was built with.
    func place(at frame: NSRect) {
        guard let window,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
        else { return }
        window.setFrame(frame, display: false)
    }

    /// Closing a window puts away what that window was showing, and nothing
    /// else. No path here closes a daemon tab, which is what makes "closing a
    /// window kills no sessions" true by construction rather than by care:
    /// the surfaces go, their clients go with them, and the shells carry on
    /// with one fewer viewer.
    func windowWillClose(_ notification: Notification) {
        session.removeWindow(windowID)
        SurfacePool.shared.discardAll(window: windowID)
        onClose?(self)
    }

    private func cancelSpring() {
        spring?.invalidate()
        spring = nil
        springTarget = nil
    }

    private func dividerMoved() {
        // A remembered width has to be put in place before a measured one is
        // believed. The split view lays out at its own natural size first,
        // and reporting that as though somebody had dragged there overwrites
        // the width they actually left it at — which is how a sidebar sized
        // by hand came back at the minimum, one launch later.
        guard hasPlacedDivider else { return }
        guard !isApplyingSnapshot, !dividerReportScheduled else { return }
        dividerReportScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.dividerReportScheduled = false
            guard let state = self.currentSidebarGeometry(),
                  state != self.applied?.sidebar
            else { return }
            self.send(.setSidebar(state))
        }
    }

    private func updateTitle(_ active: SessionSnapshot.ActiveTab) {
        let title = active.title.isEmpty ? "tab \(active.id.root)" : active.title
        if window?.title != title { window?.title = title }
    }
}

extension MainWindowController: SessionRendering {}
