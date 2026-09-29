import AppKit

/// The tab bar, drawn to match Ghostty's.
///
/// The shape of it: the selected tab is a rounded fill sitting inside the
/// titlebar row; the others are bare text on the chrome, with no separators
/// between them. Each carries its ⌘-number on the right, so the shortcut is
/// learned by being seen rather than by being looked up.
///
/// It is the app's own view rather than AppKit's tab bar because AppKit's is
/// not a bar — it is a consequence of one window per tab, and windows coming
/// and going is the bug class this shell was rebuilt to remove.
@MainActor
final class TabStripView: NSView {
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    /// A name typed over a tab's title, or nil when the typing came to
    /// nothing — Escape, or the field left as it was opened — and the
    /// keyboard only has to go back to the terminal. The row keeps no names:
    /// it says what was typed and is handed the title back like any other.
    var onRename: ((TabID, String?) -> Void)?
    /// ⌘P and ⌘⇧P, for the pointer: the overlay's two questions.
    var onGoTo: (() -> Void)?
    var onCommands: (() -> Void)?
    /// The row, in the order somebody just put it in.
    var onReorder: (([UInt32]) -> Void)?
    /// A tab pulled clear of the row and let go: where it landed, in screen
    /// coordinates, and how far along the cell it was being held. The row
    /// does not act on it — it does not know what a window is.
    var onTearOff: ((TabID, NSPoint, CGFloat) -> Void)?
    /// Told when this row's leading edge moves.
    ///
    /// Which is the sidebar's trailing edge, since the row begins where the
    /// content does. Reported from here because this is the one place that
    /// already hears about it at every frame of the sidebar's animation —
    /// a laid-out view is told its new geometry; a view watching a
    /// notification is told a story about it afterwards.
    var onLeadingEdgeMoved: ((CGFloat) -> Void)?
    private var lastLeadingEdge: CGFloat?

    /// Where the window's own chrome ends, in the window's coordinates.
    ///
    /// The toggle sits at 92 and is 26 across, so it ends at 118 — measured,
    /// not guessed. Ten points further on, a tab's capsule (inset two from its
    /// cell) starts twelve points clear of it, which is exactly the gap the
    /// row's buttons keep from the last tab at the other end. The capsule is
    /// what the eye measures from, not the close button inside it, so it is
    /// the capsule the two ends are matched on.
    private static let chromeWidth: CGFloat = 128

    /// Points kept free at the leading edge for the chrome that overlaps this
    /// row — traffic lights, sidebar toggle.
    ///
    /// Measured from where this row actually begins rather than announced by
    /// whoever last toggled the sidebar. The two agree once things have
    /// settled and they do not agree while the sidebar is moving: the row is
    /// handed its new width over two tenths of a second, and a clearance
    /// flipped in a single instant is wrong for every frame in between. Told,
    /// it went to zero the moment the sidebar began to open — while the row
    /// was still the full width of the window — and the tabs spread out under
    /// the traffic lights and the toggle before sliding back. Measured, the
    /// row simply starts wherever the chrome has stopped, at every frame,
    /// because the chrome is not going anywhere and this row is.
    private var leadingClearance: CGFloat {
        guard window != nil else { return 0 }
        return max(0, Self.chromeWidth - convert(NSPoint.zero, to: nil).x)
    }

    private var items: [SessionSnapshot.StripItem] = []
    private var cells: [TabCellView] = []
    /// A round control at the row's far end, standing on its own ground:
    /// glass where the system has it.
    private final class ChromeButton {
        let button = NSButton()
        let background: NSView = Glass.lozenge(cornerRadius: 13) ?? NSView()
        var hovered = false
    }

    /// Go To and Commands — left to right, one family of circles.
    ///
    /// New Tab is not among them. A tab is opened in a workspace, and the row
    /// shows one workspace's tabs without naming it; the sidebar names every
    /// workspace, so each one carries its own "+" there instead.
    private var chromeButtons: [ChromeButton] = []
    private let chromeIsGlass = Glass.isAvailable
    private var backgroundObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        let specs: [(symbol: String, label: String, tip: String, action: Selector)] = [
            ("magnifyingglass", "Go To", "Go To… (⌘P)", #selector(goToPressed)),
            ("command", "Commands", "Commands… (⌘⇧P)", #selector(commandsPressed)),
        ]
        for spec in specs {
            let control = ChromeButton()
            control.background.wantsLayer = true
            addSubview(control.background)

            let button = control.button
            button.image = NSImage(
                systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = spec.action
            button.toolTip = spec.tip
            button.setAccessibilityLabel(spec.label)
            addSubview(button)
            chromeButtons.append(control)
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: GhosttyApp.backgroundDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retint() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let renameWatch { NSEvent.removeMonitor(renameWatch) }
        if let fieldWatch { NSEvent.removeMonitor(fieldWatch) }
    }

    /// Which tab is at a point in this view, if any. Asked while a pane is
    /// being carried, to know which tab to spring open.
    func tab(at point: NSPoint) -> TabID? {
        guard bounds.contains(point) else { return nil }
        for (index, cell) in cells.enumerated() where cell.frame.contains(point) {
            return items[index].id
        }
        return nil
    }

    /// Empty regions stay draggable titlebar, like the tint backdrops.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Whether the window may be dragged by its titlebar right now, decided
    /// by what the pointer is over.
    ///
    /// The window server runs a titlebar drag itself, without waking the app,
    /// and the titlebar is a handle unconditionally: `mouseDownCanMoveWindow`
    /// is not consulted there, and neither the row nor a cell can refuse on
    /// its own behalf. What the window server does honour is `isMovable` —
    /// but only the answer it already has. Refusing from `mouseDown` is too
    /// late by then: the drag is underway, the window is travelling with the
    /// pointer, and a pointer that keeps its place *within* the window looks
    /// to this row exactly like a finger that never moved, which is why no
    /// tab would change place however far it was dragged.
    ///
    /// So the answer is given in advance, on hover. Over a tab the window
    /// holds still and the drag is the tab's; over the bare stretches of the
    /// row it is a titlebar again, which is what those stretches are for.
    private func updateWindowDragging(pointerAt point: NSPoint) {
        // While a tab is being carried the answer is settled, and asking
        // again mid-gesture is how the window gets let go halfway through
        // one: a drag that runs past the last tab leaves the pointer over no
        // cell at all, which reads as "not on a tab" and hands the window
        // back to the window server with the button still down.
        guard carried == nil else { return }
        // A name being typed is text: a press in it places the caret and a
        // drag selects. Neither may carry the window off, which over a lone
        // tab — the window's title, and so a handle — it otherwise would.
        if let open = cells.first(where: \.isRenaming), let field = open.editorFrame,
           open.convert(field, to: self).contains(point) {
            setWindowDraggable(false)
            return
        }
        // A lone tab is not a tab, it is the window's title — drawn without a
        // capsule for exactly that reason — and there is nowhere to reorder it
        // to. Holding the window still under it would take the title bar away
        // from a window whose title bar is all this row is.
        guard cells.count > 1 else {
            setWindowDraggable(true)
            return
        }
        setWindowDraggable(!cells.contains { $0.frame.contains(point) })
    }

    private func setWindowDraggable(_ draggable: Bool) {
        guard let window, window.isMovable != draggable else { return }
        window.isMovable = draggable
        Trace.log("strip", "window is \(draggable ? "draggable" : "held still")")
    }

    func apply(_ newItems: [SessionSnapshot.StripItem]) {
        guard newItems != items else { return }
        items = newItems

        // Reuse cells in place; a poll that only changes a title touches text.
        while cells.count < items.count {
            let cell = TabCellView()
            cell.onSelect = { [weak self] id in self?.onSelect?(id) }
            cell.onPress = { [weak self] cell, event in self?.carry(cell, from: event) }
            cell.onClose = { [weak self] id in self?.onClose?(id) }
            cell.onRename = { [weak self] id, name in self?.renamed(id, to: name) }
            cell.onRenameAsked = { [weak self] id in self?.rename(id) }
            addSubview(cell)
            cells.append(cell)
        }
        // A name being typed belongs to a tab, and a cell belongs to a place
        // in the row. When the tab changes place — one before it closing, the
        // row reordered from another window — the cell goes with it, since
        // any cell can show any tab. Settling the field instead cut the name
        // off halfway through a word, and the rest of the word went on into
        // the shell. Only a tab that has left the row settles its field, and
        // what was typed goes with it. Moved once the row has every cell it
        // needs and before any spare ones are let go, so the place it moves
        // to exists and the cell being typed in is never one of the spares.
        if let at = cells.firstIndex(where: \.isRenaming), let id = cells[at].renaming {
            if let place = items.firstIndex(where: { $0.id == id }) {
                if place != at { cells.insert(cells.remove(at: at), at: place) }
            } else {
                cells[at].finishRenaming(keep: false)
            }
        }
        while cells.count > items.count {
            cells.removeLast().removeFromSuperview()
        }
        applyCells()
        needsLayout = true
        // The row changed under whatever the pointer is doing. It may have
        // been over a tab when the window was last told to hold still, and
        // tabs closing down to one — or opening past one — changes the
        // answer without the pointer moving an inch. Nothing else asks
        // again: `mouseMoved` needs motion and `updateTrackingAreas` needs
        // the visible rect to change, and neither happens when a tab simply
        // goes away. Left unasked, a window that was holding still for a
        // drag stays unmovable afterwards.
        if let window {
            updateWindowDragging(
                pointerAt: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    private func retint() {
        applyCells()
        for control in chromeButtons { tint(control) }
    }

    private func applyCells() {
        let palette = Palette.current
        for (index, cell) in cells.enumerated() {
            cell.apply(
                items[index],
                palette: palette,
                shortcut: items.count == 1 ? nil : Self.shortcut(
                    index: index, count: items.count),
                alone: items.count == 1)
        }
    }

    /// ⌘1-8 by position and ⌘9 for the last, which is the rule the Window
    /// menu uses and the convention macOS trained.
    private static func shortcut(index: Int, count: Int) -> String? {
        if index == count - 1 && count >= 9 { return "⌘9" }
        return index < 8 ? "⌘\(index + 1)" : nil
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // A circle with a symbol in it, not a bare glyph: it reads as a
        // control, which is what it is. The same across as a tab's capsule is
        // tall, and as the sidebar toggle.
        let side: CGFloat = 26
        let gap: CGFloat = 6
        // Laid from the far end inward: the corner is the fixed point, and
        // the row of tabs ends wherever the buttons have got to.
        var buttonsStart = bounds.width - 10
        for control in chromeButtons.reversed() {
            buttonsStart -= side
            let rect = NSRect(
                x: buttonsStart, y: (height - side) / 2, width: side, height: side)
            control.button.frame = rect
            control.background.frame = rect
            if chromeIsGlass {
                Glass.setCornerRadius(control.background, side / 2)
            } else {
                control.background.layer?.cornerRadius = side / 2
            }
            tint(control)
            buttonsStart -= gap
        }
        buttonsStart += gap

        if window != nil {
            let edge = convert(NSPoint.zero, to: nil).x
            // Remembered only once it has actually been said to somebody.
            //
            // This row lays out before the window is wired up, so the first
            // edge it measures has no one to tell. Recording it anyway meant
            // recording that it had been reported, and every later layout
            // measured the same edge, found it unchanged, and stayed quiet —
            // so a window opened with the sidebar out kept its toggle beside
            // the traffic lights until something moved the sidebar.
            if edge != lastLeadingEdge, let onLeadingEdgeMoved {
                lastLeadingEdge = edge
                onLeadingEdgeMoved(edge)
            }
        }

        guard !cells.isEmpty else { return }
        let left = leadingClearance
        let available = max(0, buttonsStart - 10 - left)
        // Tabs fill the row rather than sitting in a corner of it, and they
        // share what there is rather than insisting on a width. A floor here
        // was a promise the row could not keep: past the point where the
        // floor times the count exceeded the space, the last tabs ran under
        // the buttons and off the end of the strip. Tabs give ground
        // instead, and a cell narrow enough drops what it cannot show.
        let width = available / CGFloat(cells.count)
        // The row's arithmetic, said once each time it changes. Where the
        // tabs are is the first thing anybody asks when a press lands on the
        // wrong one, and it is not otherwise recoverable from outside.
        let shape = "row clear=\(Int(left)) slot=\(Int(width)) tabs=\(cells.count)"
        if shape != lastShape {
            lastShape = shape
            Trace.log("strip", shape)
        }
        var x = left
        for cell in cells {
            // Whole pixels: a fill edge on a half pixel renders soft.
            let next = (x + width).rounded()
            let place = NSRect(x: x.rounded(), y: 0, width: next - x.rounded(), height: height)
            // The one being carried follows the pointer, not the row. Its
            // width still comes from here, so the row it is being dropped
            // into is the row it will belong to.
            if cell === carried {
                cell.frame.size = place.size
            } else if animating {
                cell.animator().frame = place
            } else {
                cell.frame = place
            }
            // A lone title is the window's title and belongs on the window's
            // centre, not on the centre of what is left after the chrome.
            cell.titleOffset = cells.count == 1 ? bounds.midX - cell.frame.midX : 0
            x = next
        }
    }

    // MARK: - carrying a tab along the row

    /// How far out of the row the pointer must go before the tab is being
    /// pulled out of it rather than along it.
    ///
    /// Generous on purpose — about one and a half rows. Reordering is done
    /// with the wrist and a wrist wanders vertically; a threshold tight
    /// enough to be crossed by accident would turn "put this tab after that
    /// one" into "make a window", which is not a mistake anybody would forgive
    /// twice. The tab visibly lifts once it is crossed, so nobody has to guess
    /// which of the two gestures they are in the middle of.
    private static let tearThreshold: CGFloat = 40

    /// The tab under the pointer, while it is being moved.
    private var carried: TabCellView?
    /// Whether the others should slide to their new places rather than jump.
    private var animating = false
    /// The last row geometry traced, so a relayout that changes nothing is
    /// not worth a line.
    private var lastShape = ""

    /// Run a tab's drag to its end.
    ///
    /// A press on a tab is not yet a move: below the threshold it is the click
    /// that selects, and a row that rearranged itself every time somebody
    /// picked a tab would be unusable. Past it, the tab follows the pointer
    /// and the rest of the row opens a place for it.
    func carry(_ cell: TabCellView, from event: NSEvent) {
        guard let item = cell.tabID else { return }
        // Read before the press has done anything, because selecting a tab
        // makes it the active one on the spot. A press on the name of the tab
        // you were already in is the one that asks for a new name.
        let wasActive = cell.isActive
        let clicks = event.clickCount
        let onName = !cell.isRenaming
            && cell.titleContains(cell.convert(event.locationInWindow, from: nil))
        // A press anywhere in the row settles a name being typed, the way a
        // click anywhere else does, and calls off one still being waited
        // for. Left open, the field would stay where it is while its tab was
        // carried away from under it.
        callOffRename()
        for open in cells { open.finishRenaming(keep: true) }
        // Nothing to rearrange, or nowhere to run a drag: the press is a
        // click and must still select. A tab that stops selecting because the
        // code that moves tabs bailed out early is worse than one that cannot
        // be moved.
        guard let window, cells.count > 1 else {
            onSelect?(item)
            guard wasActive, onName else { return }
            // A lone tab is the window's title, and the window is dragged by
            // it: the window server moves the window and the pointer keeps
            // its place within it, so a press here cannot be told from the
            // start of a drag while the press lasts. Afterwards it can, and
            // a single click waits out a pause before naming anything in any
            // case: a window that has moved by the end of it, or a button
            // still down, was a drag. A double-click is no drag, and names
            // it at once.
            if clicks >= 2 {
                rename(item)
            } else {
                rename(
                    item, after: NSEvent.doubleClickInterval,
                    unlessMovedFrom: self.window?.frame.origin)
            }
            return
        }
        // Hovering the tab said this already. Said again because a press that
        // arrives without one — the app activated by this very click, the
        // pointer never having moved since — would otherwise leave the window
        // movable for the whole drag. Too late for this press, in time for
        // the next.
        setWindowDraggable(false)

        let start = convert(event.locationInWindow, from: nil)
        let originX = cell.frame.minX
        let originY = cell.frame.minY
        var moved = false
        var tearing = false
        var sawDrag = 0
        Trace.log("strip", "press on \(item.root) at \(Int(start.x))")

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { [weak self] event, stop in
            guard let self, let event else {
                stop.pointee = true
                return
            }
            // Where the pointer is, asked of the pointer.
            //
            // Not of the event: `locationInWindow` is relative to whichever
            // window the event belongs to, and a drag that wanders over
            // another window of this same app stops belonging to this one.
            // The events keep arriving — the press captured the mouse — but
            // their coordinates are then measured from somewhere else, and a
            // tab dragged onto the next window reads from in here as a tab
            // that never left the row. It lands back where it started, and
            // nothing anywhere says why.
            let onScreen = NSEvent.mouseLocation
            let point = self.convert(window.convertPoint(fromScreen: onScreen), from: nil)
            switch event.type {
            case .leftMouseDragged:
                sawDrag += 1
                if !moved {
                    // Distance, not horizontal distance. Measured along one
                    // axis, a straight pull downwards never became a carry at
                    // all: it stayed a press and was released as a click,
                    // which is exactly the motion somebody makes to take a
                    // tab out of the row.
                    guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
                    moved = true
                    Trace.log("strip", "carrying \(item.root)")
                    self.carried = cell
                    // Above the others, so it passes over them rather than
                    // through them.
                    self.addSubview(cell, positioned: .above, relativeTo: nil)
                }

                let tearingNow = self.isOutOfTheRow(point)
                if tearingNow != tearing {
                    tearing = tearingNow
                    Trace.log("strip", tearing ? "tearing \(item.root)" : "back in the row")
                    // Said again on the way out: a press that arrived without
                    // a hover leaves the window movable, and a tab pulled
                    // downwards out of a titlebar is precisely the gesture the
                    // window server reads as "drag me".
                    if tearing { self.setWindowDraggable(false) }
                    cell.animator().alphaValue = tearing ? 0.65 : 1
                }

                cell.frame.origin.x = originX + (point.x - start.x)
                if tearing {
                    // Both axes now, so the tab follows the hand out of the
                    // row instead of sliding along a rail it has left. The
                    // row closes the gap and stays closed: `settle` would go
                    // on shuffling places for a tab that is no longer in any
                    // of them.
                    cell.frame.origin.y = originY + (point.y - start.y)
                } else {
                    cell.frame.origin.y = originY
                    self.settle(cell)
                }

            case .leftMouseUp:
                defer { stop.pointee = true }
                self.carried = nil
                cell.alphaValue = 1
                if tearing {
                    self.needsLayout = true
                    Trace.log("strip", "torn off \(item.root)")
                    self.onTearOff?(item, onScreen, start.x - originX)
                } else if moved {
                    self.needsLayout = true
                    let order = self.cells.compactMap(\.tabID?.root)
                    Trace.log("strip", "dropped, order now \(order)")
                    self.onReorder?(order)
                } else if wasActive && onName {
                    // Finder's gesture, on the one tab that selecting would
                    // not change. Selected all the same, as every click on a
                    // tab is: that is what brings the keyboard back to the
                    // terminal from wherever it had gone, and a click that
                    // stopped doing so on the tab most clicked would be missed
                    // on the first keystroke. The field asks for the keyboard
                    // a turn later at the soonest, so it still gets it.
                    Trace.log("strip", "released on the name of \(item.root)")
                    self.onSelect?(item)
                    self.rename(item, after: clicks >= 2 ? 0 : NSEvent.doubleClickInterval)
                } else {
                    Trace.log("strip", "released after \(sawDrag) drag events; treated as a click")
                    self.onSelect?(item)
                }

            default:
                break
            }
        }
        // `trackEvents` returns only once the drag is over, however it ended.
        // Where the pointer came to rest decides, not where it started: a tab
        // dropped under the pointer should still be holding the window.
        updateWindowDragging(
            pointerAt: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Whether the pointer has left the row, far enough to mean it.
    ///
    /// Vertical only. Dragging past either end of the row sideways is how a
    /// tab is put first or last, and always has been; it is leaving the row's
    /// *band* — up over the top of the window, or down into the terminal —
    /// that has no meaning inside the row and so is free to mean this.
    private func isOutOfTheRow(_ point: NSPoint) -> Bool {
        point.y < -Self.tearThreshold || point.y > bounds.height + Self.tearThreshold
    }

    /// Move the carried tab into the place its middle is over, and let the
    /// others slide.
    ///
    /// The place, not a fixed distance. A tab is as wide as the row allows,
    /// which is a third of a wide window and a ninth of a narrow one, so any
    /// number of points chosen here would be several places in one window and
    /// a fraction of one in the next.
    private func settle(_ cell: TabCellView) {
        guard let at = cells.firstIndex(of: cell) else { return }
        let width = cell.frame.width
        guard width > 0 else { return }
        let target = min(
            cells.count - 1,
            max(0, Int(((cell.frame.midX - leadingClearance) / width).rounded(.down))))
        guard target != at else { return }
        cells.remove(at: at)
        cells.insert(cell, at: target)
        Trace.log("strip", "moved to place \(target)")
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            layout()
        }
        animating = false
    }

    // MARK: - naming a tab

    /// Bumped to call off a name that was asked for and has not opened yet.
    /// The wait is a turn of the run loop already queued, which cannot be
    /// taken back — only told, when it arrives, that it is no longer wanted.
    private var renameTicket = 0
    /// Listening, while a name waits out its pause, for anything else being
    /// done in the meantime.
    private var renameWatch: Any?
    /// Listening, while a name is being typed, for a press anywhere else in
    /// the window.
    private var fieldWatch: Any?

    /// Call off a name that was asked for and has not opened yet.
    private func callOffRename() {
        renameTicket += 1
        if let renameWatch { NSEvent.removeMonitor(renameWatch) }
        renameWatch = nil
    }

    /// Open a tab's title for typing.
    ///
    /// After a pause when the press was a single click, which is how Finder
    /// does it and why: the click may be the first half of a double-click,
    /// and a field open in time for the second half would take it as a word
    /// to select. A double-click opens it at once.
    ///
    /// Never in the same turn, even then. One name is typed at a time, so a
    /// field already open is settled first, and its answer is a turn away,
    /// handing the keyboard to the terminal when it lands. Queued behind
    /// it, this field takes the keyboard after rather than having it taken.
    ///
    /// `origin` is where the window was when the press came, for a press
    /// that may have been the start of a window drag instead: the field does
    /// not open if the window has moved since, or if the button that might
    /// be moving it is still down.
    private func rename(
        _ id: TabID, after delay: TimeInterval = 0, unlessMovedFrom origin: NSPoint? = nil
    ) {
        callOffRename()
        let ticket = renameTicket
        for open in cells { open.finishRenaming(keep: true) }
        let begin = { [weak self] in
            guard let self, self.renameTicket == ticket else { return }
            self.callOffRename()
            guard let window = self.window, window.isKeyWindow,
                  !self.isHiddenOrHasHiddenAncestor,
                  let cell = self.cells.first(where: { $0.tabID == id }),
                  delay == 0 || cell.isActive
            else { return }
            if let origin,
               window.frame.origin != origin || NSEvent.pressedMouseButtons & 1 != 0 {
                Trace.log("strip", "the press on \(id.root) was a drag")
                return
            }
            guard cell.beginRenaming() else { return }
            self.watchPresses()
            Trace.log("strip", "renaming \(id.root)")
            self.updateWindowDragging(
                pointerAt: self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        guard delay > 0 else {
            DispatchQueue.main.async(execute: begin)
            return
        }
        // Anything else done during the pause — a click in the terminal, a
        // key typed into it — means the click on the name was not asking
        // for one. Finder calls its rename off the same way, and a field
        // opened regardless would take the keystrokes meant for the shell.
        renameWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.callOffRename() }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: begin)
    }

    /// Settle the field on a press that would not settle it by itself.
    ///
    /// Most presses end it by taking the keyboard — the terminal, a field in
    /// the sidebar, the overlay. The rest take nothing: the bare row, the
    /// titlebar, the sidebar's ground, the toggle. Under those the field
    /// stayed open with its caret, after a click that meant to leave it, and
    /// took the next keystrokes as more of the name. Kept, as a click that
    /// does take the keyboard keeps it.
    private func watchPresses() {
        guard fieldWatch == nil else { return }
        fieldWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window,
                      let open = self.cells.first(where: \.isRenaming)
                else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                // A press in the field places the caret or selects. A press on
                // a tab is the row's own, and `carry` settles the field itself,
                // having first read what the press was on.
                if let field = open.editorFrame,
                   open.convert(field, to: self).contains(point) { return }
                if event.type == .leftMouseDown, self.tab(at: point) != nil { return }
                open.finishRenaming(keep: true)
            }
            return event
        }
    }

    /// What a cell's field came to, passed on a turn later.
    ///
    /// Later, because most fields end by losing the keyboard — a click in the
    /// terminal or on another tab, ⌘1–9, ⌘P — and the keyboard is moved from
    /// inside somebody else's render. Answering there would dispatch inside a
    /// dispatch and render a snapshot while the last one was still going up.
    private func renamed(_ id: TabID, to name: String?) {
        if let fieldWatch, !cells.contains(where: \.isRenaming) {
            NSEvent.removeMonitor(fieldWatch)
            self.fieldWatch = nil
        }
        if let window {
            updateWindowDragging(
                pointerAt: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let name {
                Trace.log("strip", "renamed \(id.root)")
                self.onRename?(id, name)
            } else if self.keyboardIsLoose {
                // Nothing to keep, and the keyboard went nowhere on the way
                // out, so it goes back to the terminal. A field left by a
                // click somewhere else leaves the keyboard where that click
                // put it.
                self.onRename?(id, nil)
            }
        }
    }

    /// Whether nobody has the keyboard: the window itself, or a field in
    /// this row that has since been put away.
    private var keyboardIsLoose: Bool {
        guard let window else { return false }
        let holder = window.firstResponder
        if holder == nil || holder === window { return true }
        guard let view = holder as? NSView, view.isDescendant(of: self) else { return false }
        return !cells.contains { $0.isRenaming }
    }

    /// A row put away — vertical tabs — settles the name being typed in it,
    /// and calls off one still being waited for.
    override func viewDidHide() {
        super.viewDidHide()
        callOffRename()
        for cell in cells { cell.finishRenaming(keep: true) }
    }

    /// Untinted glass at rest, which refracts darker than the bar and reads
    /// as a well rather than a lamp; tinted only under the pointer.
    private func tint(_ control: ChromeButton) {
        if chromeIsGlass {
            Glass.tint(control.background, control.hovered ? Palette.current.glassTint : nil)
        } else {
            control.background.layer?.backgroundColor = Palette.current.controlFill.cgColor
        }
        control.button.contentTintColor = control.hovered
            ? Palette.current.text
            : Palette.current.dimText
    }

    /// One tracking area for the whole row.
    ///
    /// Per-cell areas alone left a close button showing after the pointer had
    /// gone: a cell that is resized or reused out from under the mouse never
    /// hears `mouseExited`. The row knows when the mouse has left it entirely,
    /// and that is the only moment every cell can be told at once.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
        // Where the pointer is, rather than where it was last seen moving.
        // Tabs open and close and the row relays itself under a pointer that
        // is holding still, and a window's movability decided only on motion
        // would keep answering for a tab that is no longer there.
        if let window {
            updateWindowDragging(
                pointerAt: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateWindowDragging(pointerAt: point)
        for control in chromeButtons {
            let over = control.background.frame.contains(point)
            guard over != control.hovered else { continue }
            control.hovered = over
            tint(control)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setWindowDraggable(true)
        for control in chromeButtons where control.hovered {
            control.hovered = false
            tint(control)
        }
        for cell in cells { cell.clearHover() }
    }

    /// A row taken out of its window leaves that window movable, whatever the
    /// pointer was over when it went.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { setWindowDraggable(true) }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func goToPressed() {
        onGoTo?()
    }

    @objc private func commandsPressed() {
        onCommands?()
    }

    /// Colours resolved from the terminal background's luminance, so the bar
    /// belongs to whatever theme the terminal is wearing.
    struct Palette: Equatable {
        /// Whether the ground is dark: the question every colour here is an
        /// answer to, kept for the colours that come from elsewhere and ask
        /// it too — Claude Code's, for its modes.
        let dark: Bool
        let text: NSColor
        let dimText: NSColor
        /// A title under the pointer. Between the two above on purpose: a tab
        /// being offered should answer, and still not answer as loudly as the
        /// tab you are actually in.
        let hoverText: NSColor
        /// The selected tab's fill. Nothing paints the unselected ones.
        let selectedFill: NSColor
        /// The faint capsule an unselected tab wears under the pointer.
        let hoverFill: NSColor
        /// The hairline around the selected tab.
        let edge: NSColor
        /// The round buttons' ground where there is no glass to stand them on.
        let controlFill: NSColor
        /// What glass is aimed at. Refraction alone comes out darker than a
        /// dark bar, and the shape this is modelled on is lighter than one.
        let glassTint: NSColor

        static var current: Palette {
            // Until libghostty has said what the ground is, the system's
            // appearance is the best guess — the window follows the same
            // one until then. Guessing black instead put white ink on the
            // white titlebar of a light macOS.
            let dark = GhosttyApp.shared.groundIsDark
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let ink: NSColor = dark ? .white : .black
            return Palette(
                dark: dark,
                text: ink.withAlphaComponent(dark ? 0.92 : 0.85),
                dimText: ink.withAlphaComponent(0.45),
                hoverText: ink.withAlphaComponent(dark ? 0.72 : 0.66),
                selectedFill: ink.withAlphaComponent(dark ? 0.14 : 0.09),
                hoverFill: ink.withAlphaComponent(dark ? 0.05 : 0.035),
                edge: ink.withAlphaComponent(dark ? 0.16 : 0.10),
                controlFill: ink.withAlphaComponent(dark ? 0.09 : 0.06),
                glassTint: ink.withAlphaComponent(dark ? 0.22 : 0.14)
            )
        }
    }
}

/// One tab: a rounded fill when selected, bare text when not.
@MainActor
final class TabCellView: NSView {
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    /// What the field came to: the name typed, or nil for nothing to keep.
    var onRename: ((TabID, String?) -> Void)?
    /// "Rename Tab…" from the menu. The row decides when the field opens.
    var onRenameAsked: ((TabID) -> Void)?

    private var item: SessionSnapshot.StripItem?
    private var palette: TabStripView.Palette?
    private var shortcut: String?
    private var hovered = false
    /// Whether this is the only tab there is. One tab is not a choice between
    /// tabs, so it is not drawn as one: no capsule, no number, no close
    /// button — just the title, and a window that reads as one thing.
    private var alone = false
    /// How far the title has to move to sit on the window's centre rather
    /// than on this cell's. Only a lone title asks for it.
    var titleOffset: CGFloat = 0 {
        didSet { if titleOffset != oldValue { needsLayout = true } }
    }

    /// The selected tab's capsule, in glass where the system has it.
    ///
    /// Two things had to be right for it to read: a glass view refracts what
    /// is behind it and needs a light tint to come out lighter than a dark
    /// bar rather than darker, and a border must not be set on its layer —
    /// that layer is a plain rectangle, so the hairline came out as a box
    /// around the capsule instead of following it. Glass carries its own
    /// edge; it does not want one drawn on.
    private let fill: NSView = Glass.lozenge(cornerRadius: 12) ?? NSView()
    private let fillIsGlass = Glass.isAvailable
    /// The capsule an unselected tab wears under the pointer.
    ///
    /// Flat, and its own view rather than the selected tab's. That one is
    /// glass, and glass under a hover refracts into a dark well: it reads as a
    /// hole punched in the bar rather than as a tab being offered, which is
    /// why hovering used to paint nothing at all. A plain tint is what being
    /// offered looks like, and it is what the palette named this colour for.
    private let hoverFill = NSView()
    /// Whether the capsule is currently being offered, so that a poll which
    /// only changed a title does not restart the fade.
    private var offering = false
    /// The badge a tab wears while Claude Code waits on an answer in it —
    /// `Attention` — over the selection's glass and in its place, since a
    /// tab asking for you is the one thing in the row that must not read as
    /// just another title.
    private let attention = NSView()
    /// Until when the badge breathes, and in which colours, so that a poll
    /// which changes nothing does not start the breath over.
    private var breathing: (until: Date?, dark: Bool)?
    private let label = NSTextField(labelWithString: "")
    /// Kept, because how much room the title is owed changes with how much
    /// room the tab has. As inequalities against a centred label they become
    /// unsatisfiable in a narrow cell — 28 in from the left and 36 in from the
    /// right do not both fit in 40 points — and AppKit resolves that by
    /// breaking one and saying so.
    private var labelCenter: NSLayoutConstraint!
    private var labelLeading: NSLayoutConstraint!
    private var labelTrailing: NSLayoutConstraint!
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    /// The field a new name is typed into, laid over the title while it is.
    ///
    /// A field of its own rather than the title made editable. The title is
    /// rewritten whenever its program retitles itself — several times a
    /// second while Claude Code works — and a title that was also the field
    /// would take back every letter as it was typed.
    private let editor = NSTextField()
    /// The tab the field is naming, taken when it opened. Cells are reused by
    /// place, not by tab, and by the time the name is settled this cell may
    /// be showing another one.
    private(set) var renaming: TabID?
    /// What the field opened with, so that leaving it untouched can be told
    /// apart from choosing that name: a title kept by accident would stop
    /// following its program, and nobody would know why.
    private var seed = ""

    /// How tall a tab's capsule is: what the titlebar row left it at thirteen
    /// points off each edge, and the same across as the chrome buttons. Kept
    /// in a shorter row too — full screen's, which has no traffic lights to
    /// line up with — by taking less off the edges, never off the capsule.
    private let capsuleHeight: CGFloat = 26
    /// Half the gap between two capsules: each tab insets its own fill, so
    /// neighbours end up twice this far apart.
    private let horizontalInset: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Under everything, including the selected tab's glass: the two are
        // never shown together, but the order says which is the ground.
        hoverFill.wantsLayer = true
        hoverFill.layer?.cornerCurve = .continuous
        hoverFill.alphaValue = 0
        addSubview(hoverFill)

        fill.wantsLayer = true
        if !fillIsGlass { fill.layer?.cornerCurve = .continuous }
        addSubview(fill)

        // Over the glass: a tab asking for you is still the tab you are in,
        // and the badge says the more urgent of the two.
        attention.wantsLayer = true
        attention.layer?.cornerCurve = .continuous
        attention.isHidden = true
        addSubview(attention)

        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // Bare text in the title's place and weight, so that a tab being
        // named still looks like a tab. The selection shows it is a field.
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.isEditable = true
        editor.isSelectable = true
        editor.font = .systemFont(ofSize: 12, weight: .medium)
        editor.alignment = .center
        editor.usesSingleLineMode = true
        editor.maximumNumberOfLines = 1
        editor.cell?.wraps = false
        editor.cell?.isScrollable = true
        editor.isHidden = true
        editor.delegate = self
        editor.setAccessibilityLabel("Tab Name")
        addSubview(editor)

        labelCenter = label.centerXAnchor.constraint(equalTo: centerXAnchor)
        labelLeading = label.leadingAnchor.constraint(
            greaterThanOrEqualTo: leadingAnchor, constant: 28)
        labelTrailing = label.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -36)

        NSLayoutConstraint.activate([
            labelCenter,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelLeading,
            labelTrailing,

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let verticalInset = max(2, ((bounds.height - capsuleHeight) / 2).rounded(.down))
        fill.frame = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        // A capsule: the radius is half the height, which is the shape a tab
        // lozenge has.
        let radius = fill.frame.height / 2
        if fillIsGlass {
            Glass.setCornerRadius(fill, radius)
        } else {
            fill.layer?.cornerRadius = radius
        }
        // The same shape in the same place, so that hovering a tab and then
        // choosing it is one capsule firming up rather than two capsules.
        hoverFill.frame = fill.frame
        hoverFill.layer?.cornerRadius = radius
        // The badge takes the capsule's place — except on a lone tab, which
        // has no capsule and spans the row: there it hugs the title, where
        // the eye is, rather than lighting up the whole titlebar.
        if alone {
            let title = label.frame
            attention.frame = NSRect(
                x: (title.minX - 12).rounded(), y: fill.frame.minY,
                width: (title.width + 24).rounded(), height: fill.frame.height)
        } else {
            attention.frame = fill.frame
        }
        attention.layer?.cornerRadius = radius
        // What a tab shows is decided by how much of it there is. The number
        // is a hint and steps aside first; the close button goes next, since
        // a tab too narrow to name is not one to be closed by aim; the title
        // is last, and truncates. Each thing that leaves gives its room back
        // to the title.
        //
        // A tab being named shows the name and nothing else: the number and
        // the close button would only crowd the field, and a close button
        // appearing under the pointer mid-word is a tab closed by accident.
        let naming = renaming != nil
        shortcutLabel.isHidden = naming || shortcut == nil || bounds.width < 160
        closeButton.isHidden = naming || !hovered || alone || bounds.width < 96
        labelLeading.constant = closeButton.isHidden ? 8 : 28
        labelTrailing.constant = shortcutLabel.isHidden ? -8 : -36
        labelCenter.constant = titleOffset

        // Shown and hidden here rather than where the naming starts and
        // stops. It mostly stops because the keyboard has just gone
        // somewhere else, and hiding a field in the middle of that — while
        // AppKit is still handing the keyboard over — makes it choose a new
        // holder of its own, from inside the handover.
        label.isHidden = naming
        editor.isHidden = !naming
        if naming {
            // On the title's centre, which for a lone tab is the window's.
            // As wide as a name needs rather than as the tab is: a lone tab
            // spans the whole row, and a field that wide would take presses
            // meant for the titlebar around it.
            let height = ceil(editor.intrinsicContentSize.height)
            let width = max(0, min(bounds.width - 28, 320))
            let centre = bounds.midX + titleOffset
            let x = min(max(14, centre - width / 2), bounds.width - 14 - width)
            editor.frame = NSRect(
                x: x.rounded(), y: ((bounds.height - height) / 2).rounded(),
                width: width, height: height)
        }
    }

    func apply(
        _ item: SessionSnapshot.StripItem,
        palette: TabStripView.Palette,
        shortcut: String?,
        alone: Bool
    ) {
        self.item = item
        self.palette = palette
        self.shortcut = shortcut
        self.alone = alone

        let wantsYou = item.claudeActivity?.wantsYou == true
        var title = item.title.isEmpty ? "untitled" : item.title
        if wantsYou {
            // The hand goes where the marks were: Claude Code's `✳` and its
            // spinner say it is running, which is not the news.
            title = Session.plainTitle(title, fallback: "untitled")
        } else if item.busy && !title.hasPrefix("✳") {
            // Unless the title already says so — programs that title
            // themselves with the same mark were showing it twice.
            title = "✳ \(title)"
        }
        let font = NSFont.systemFont(
            ofSize: 12, weight: wantsYou ? .semibold : item.isActive ? .medium : .regular)
        label.font = font

        // The tab you are in already answers, and a lone tab is a window
        // title with nothing to choose between — neither is an offer, so
        // neither takes one.
        let offering = hovered && !item.isActive && !alone && !wantsYou
        // A turn under way in the manual mode, which has no colour of its
        // own, is not left the dimmest title in the row: a finished turn's
        // grey would outshine it.
        let ink = item.isActive || alone
            ? palette.text
            : (offering || item.claudeActivity == .working ? palette.hoverText : palette.dimText)
        // A tab running Claude Code in one of its modes wears that mode's
        // colour, the one its footer is written in, so a tab left in bypass
        // reads as one from across the row. Only the colour: the weight and
        // the capsule still say which tab you are in.
        // Where the turn stands wins over the mode when it has a colour of
        // its own: waiting on a workflow, waiting on you, or over.
        label.textColor = item.claudeActivity?.color(dark: palette.dark)
            ?? item.claudeMode?.color(dark: palette.dark) ?? ink
        hoverFill.layer?.backgroundColor = palette.hoverFill.cgColor
        offer(offering)

        // One capsule in the row: the tab you are in. The others are text on
        // the chrome until the pointer is over them.
        if fillIsGlass {
            fill.isHidden = !item.isActive || alone
            Glass.tint(fill, palette.glassTint)
        } else {
            fill.isHidden = !item.isActive || alone
            fill.layer?.borderWidth = 1
            fill.layer?.borderColor = palette.edge.cgColor
            fill.layer?.backgroundColor = palette.selectedFill.cgColor
        }
        // A tab waiting on you wears the badge, and the hover's faint capsule
        // under it would only muddy the orange.
        attention.isHidden = !wantsYou
        if wantsYou {
            attention.layer?.backgroundColor = Attention.fill(dark: palette.dark).cgColor
        }
        // Breathing for a while after it starts waiting, and only out of
        // sight: the tab you are in is in front of you already, and a badge
        // pulsing under the thing you are reading would be a light left
        // flashing in your face.
        let breathe = (
            until: wantsYou && !item.isActive ? Attention.lastBreath(since: item.wantsYouSince) : nil,
            dark: palette.dark)
        if breathing?.until != breathe.until || breathing?.dark != breathe.dark {
            breathing = breathe
            if let layer = attention.layer {
                Attention.pulse(layer, dark: breathe.dark, until: breathe.until)
            }
        }

        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.textColor = wantsYou ? Attention.ink.withAlphaComponent(0.6) : palette.dimText
        closeButton.contentTintColor = wantsYou ? Attention.ink : palette.text

        // What a tab is, beside what it is called: split into panes, and open
        // in another window as well. Drawn as symbols rather than as the box
        // characters they used to be — a glyph borrowed from a font is at the
        // mercy of whichever face has it, and `⊞` came out as a chequerboard
        // rather than as a pane.
        var marks: [String] = []
        if item.hasPanes { marks.append("rectangle.split.2x1") }
        if item.isElsewhere { marks.append("macwindow.on.rectangle") }
        let colour = label.textColor ?? palette.text
        if marks.isEmpty && !wantsYou {
            if label.stringValue != title { label.stringValue = title }
        } else {
            let line = NSMutableAttributedString()
            if wantsYou {
                line.append(Self.symbol(Attention.symbol, colour: colour, size: font.pointSize))
                line.append(NSAttributedString(string: " "))
            }
            line.append(NSAttributedString(
                string: title, attributes: [.font: font, .foregroundColor: colour]))
            for mark in marks {
                line.append(NSAttributedString(string: "  "))
                line.append(Self.symbol(mark, colour: colour, size: font.pointSize))
            }
            label.attributedStringValue = line
        }

        let said = wantsYou ? "\(title) — Claude Code is waiting for you" : title
        setAccessibilityLabel(said)
        toolTip = item.isElsewhere
            ? "\(wantsYou ? said : item.title) — open in another window"
            : (wantsYou ? said : item.title)
        needsLayout = true
    }

    /// One SF Symbol, sized and coloured to sit in a line of text.
    ///
    /// As an attachment rather than as an image view: it belongs *after* the
    /// title, however long the title turns out to be, and a field that
    /// truncates its text must be free to truncate around it.
    private static func symbol(_ name: String, colour: NSColor, size: CGFloat)
        -> NSAttributedString
    {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString(string: "") }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Dropped onto the text's own baseline; an attachment sits on the
        // line's bottom otherwise, which puts it a couple of points low.
        attachment.bounds = NSRect(
            x: 0, y: -1, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// Cells are reused and resized as tabs come and go, and a cell that
    /// moves out from under the pointer is never sent `mouseExited`. Asking
    /// where the mouse actually is settles it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        let inside = window.map { window -> Bool in
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.contains(point)
        } ?? false
        if inside != hovered {
            hovered = inside
            refresh()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovered else { return }
        hovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// Fade the capsule in or out, and only when the answer has changed: a
    /// poll arrives every so often and would otherwise restart the fade from
    /// the top while the pointer sits perfectly still.
    private func offer(_ offering: Bool) {
        guard offering != self.offering else { return }
        self.offering = offering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverFill.animator().alphaValue = offering ? 1 : 0
        }
    }

    /// Told from the row that the pointer is gone, for the case AppKit does
    /// not say so itself.
    func clearHover() {
        guard hovered else { return }
        hovered = false
        refresh()
    }

    private func refresh() {
        if let item, let palette {
            apply(item, palette: palette, shortcut: shortcut, alone: alone)
        }
    }

    /// Which tab this cell is showing, for the row that reorders them.
    var tabID: TabID? { item?.id }
    var isActive: Bool { item?.isActive ?? false }
    var isRenaming: Bool { renaming != nil }
    /// Where the field is while a name is being typed, in this cell's
    /// coordinates.
    var editorFrame: NSRect? { renaming == nil ? nil : editor.frame }

    /// Whether a point in this cell is on the tab's name rather than beside
    /// it. A few points of grace around the text, which is small to aim at.
    func titleContains(_ point: NSPoint) -> Bool {
        !label.isHidden && label.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Open the field over the title, holding the title as it reads now.
    ///
    /// Without the marks: the busy `✳` and the spinner's frames are the
    /// program talking, not part of the name, and a name kept with one in it
    /// would show a busy tab long after the work was done.
    @discardableResult
    func beginRenaming() -> Bool {
        guard renaming == nil, let item, let palette, let window else { return false }
        renaming = item.id
        seed = Session.plainTitle(item.title, fallback: "")
        editor.stringValue = seed
        editor.textColor = palette.text
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard window.makeFirstResponder(editor) else {
            renaming = nil
            needsLayout = true
            return false
        }
        // The caret in the title's own ink. The field editor is shared and
        // handed round, so it is said each time, as the picker does.
        if let text = editor.currentEditor() as? NSTextView {
            text.insertionPointColor = palette.text
            text.selectAll(nil)
        }
        return true
    }

    /// Settle the field from outside it — Return, Escape, a press elsewhere
    /// in the row, or the row finding its tab gone. `keep` is whether what
    /// was typed is the answer.
    func finishRenaming(keep: Bool) {
        guard let id = renaming else { return }
        let typed = editor.currentEditor()?.string ?? editor.stringValue
        renaming = nil
        // The keyboard is let go of while the field is still showing, and
        // left with the window until the answer comes back and puts it on
        // the terminal. A field hidden while it holds the keyboard hands it
        // to whatever AppKit picks next.
        if editor.currentEditor() != nil { window?.makeFirstResponder(nil) }
        needsLayout = true
        onRename?(id, keep && typed != seed ? typed : nil)
    }

    /// Every press inside a tab is the tab's, wherever it lands.
    ///
    /// A cell is made of a pane of glass and two labels, and a press that
    /// lands on one of those is that view's press, not the cell's — which
    /// meant it never reached the code that moves tabs at all. The close
    /// button is a control and keeps its clicks; everything else in here is
    /// decoration — except a name being typed, whose presses place the caret
    /// and select, as in any field.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        if renaming != nil, editor.frame.contains(local) {
            return editor.hitTest(local) ?? editor
        }
        return self
    }

    /// A tab's own menu: naming it and closing it, the two things done to
    /// one tab rather than to the row.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard item != nil else { return nil }
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: "Rename Tab…", action: #selector(renamePicked), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        let close = NSMenuItem(
            title: "Close Tab", action: #selector(closePressed), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func renamePicked() {
        if let item { onRenameAsked?(item.id) }
    }

    /// The press is handed to the row rather than answered here: it might be
    /// a click that selects, or the start of a move, and only the row knows
    /// what the others should do while that is being decided.
    override func mouseDown(with event: NSEvent) {
        guard let onPress else {
            if let item { onSelect?(item.id) }
            return
        }
        onPress(self, event)
    }

    var onPress: ((TabCellView, NSEvent) -> Void)?

    override func accessibilityPerformPress() -> Bool {
        if let item { onSelect?(item.id); return true }
        return false
    }

    @objc private func closePressed() {
        if let item { onClose?(item.id) }
    }
}

// MARK: - keyboard

extension TabCellView: NSTextFieldDelegate {
    /// Return keeps the name, and so do Tab and ⇧Tab, which have nowhere else
    /// in the row to go; Escape takes it back.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            finishRenaming(keep: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRenaming(keep: false)
            return true
        default:
            return false
        }
    }

    /// The keyboard went somewhere else — a click in the terminal or on
    /// another tab, ⌘1–9, ⌘P. What was typed is kept, as Finder keeps it.
    ///
    /// Also told when the field is settled from outside, since that lets go
    /// of the keyboard too; by then there is nothing left here to settle.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let id = renaming else { return }
        renaming = nil
        needsLayout = true
        let typed = editor.stringValue
        onRename?(id, typed != seed ? typed : nil)
    }
}
