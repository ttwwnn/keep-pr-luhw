import AppKit
import GhosttyKit
import QuartzCore

/// An `NSView` that libghostty renders a terminal into.
///
/// Drawing does not happen in SwiftUI: a character grid at frame rate needs a
/// real view with a Metal layer, which is exactly how Ghostty itself is built.
///
/// Surfaces are expensive — each owns a renderer and a `keep` client process —
/// so they are created once (see SurfacePool) and then mounted forever inside
/// the one window, mostly hidden. Visibility, not existence, is what changes
/// on a switch, and everything here is built around that:
///
/// - A hidden surface draws zero frames and defers PTY resizes; its Metal
///   layer keeps the last presented frame, so revealing it never shows a hole
///   even before the fresh draw lands.
/// - Drawing is on-demand where the runtime allows: the first
///   `GHOSTTY_ACTION_RENDER` a surface receives proves this build asks for
///   draws, and the free-running display link retires for good. Until that
///   proof, the link runs while visible — the conservative fallback.
final class TerminalSurfaceView: NSView {
    private var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?
    private var occlusionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var drawCount = 0
    private var traceTimer: Timer?
    private let workspace: String
    let tab: UInt32

    /// Set once the runtime sends this surface a render request. From then on
    /// draws happen only when asked for, and the display link stays off.
    private var renderDriven = false

    /// The framebuffer size last actually sent, so layout passes that change
    /// nothing send nothing (they used to send everything twice).
    private var sentSize: CGSize?

    /// A resize that arrived while hidden. Only the visible tab's sessions
    /// re-wrap live during a window resize; the rest catch up in one call
    /// when revealed.
    private var pendingSize: CGSize?

    /// The active pane reports focus upward; the model owns the fact.
    var onFocusGained: (() -> Void)?
    /// The title the program inside just set, as it set it.
    ///
    /// The daemon reports titles too, and the app has always taken them from
    /// there — but it asks every two seconds, and a program that spins its
    /// title is redrawing it several times a second. Two seconds of that is
    /// a still frame of an animation.
    var onTitle: ((String) -> Void)?

    /// Whether the pointer is currently showing the column-selection shape.
    private var showingColumnCursor = false

    /// What the input system is still putting together: an accent waiting
    /// for its letter, or a word an input method has not committed yet.
    ///
    /// Held here and shown by libghostty as preedit, because until it is
    /// committed it is not input — the program on the other end must never
    /// see the accent on its own and then the letter on its own.
    private var markedText = NSMutableAttributedString()

    /// The text the input system committed during the key press being
    /// handled, or nil outside one — which is how `insertText` tells a key
    /// it is answering from dictation or the character viewer arriving on
    /// their own.
    private var keyTextAccumulator: [String]?

    /// The commands AppKit mapped the key being handled to — insertNewline:,
    /// deleteBackward:, moveLeft: — or nil outside a key press. A key that
    /// comes back as a command after a commit was not spent on committing.
    private var keyCommands: [Selector]?

    init(workspace: String, tab: UInt32) {
        self.workspace = workspace
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        // Without this the view keeps its own backing store and libghostty
        // draws into something the window never composites.
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes(DroppedFiles.types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        traceTimer?.invalidate()
        if let link = displayLink { CVDisplayLinkStop(link) }
        if let surface {
            GhosttyApp.shared.unregister(surface: surface)
            ghostty_surface_free(surface)
        }
        if let watchFile {
            try? FileManager.default.removeItem(at: watchFile.deletingLastPathComponent())
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// A click on a window that is not in front reaches the terminal, rather
    /// than only bringing the window forward.
    ///
    /// AppKit's default is to spend that click on activation and deliver
    /// nothing, which is right for a button — you would not want to press one
    /// by accident on the way past — and wrong for a terminal, where the click
    /// is where you want the cursor or where a selection starts. Without this
    /// every visit to an unfocused window cost a click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeOcclusion()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyApp.shared.app else { return }

        var config = ghostty_surface_config_new()
        // Callbacks that are not actions -- reading the clipboard, above all
        // -- arrive with nothing but this pointer to say which surface asked.
        // Unretained: the view owns the surface, never the other way round.
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)

        // Which workspace and tab this surface should attach to travels
        // through the working directory: of the per-surface fields, that is
        // the only one this build of libghostty honours. `command`,
        // `env_vars` and `initial_input` are accepted by the API and then
        // ignored, which is why the client is fixed app-wide (GhosttyApp)
        // and the target is a file the client reads and deletes.
        guard let target = Self.makeTargetDirectory(workspace: workspace, tab: tab) else { return }
        watchFile = target.watch
        noteShowing()  // a surface born into a hidden host is never told it is hidden
        target.path.withCString { wd in
            config.working_directory = wd
            surface = ghostty_surface_new(app, &config)
        }

        guard let surface else { return }
        GhosttyApp.shared.register(surface: surface, view: self)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: GhosttyApp.backgroundDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.paintVeil()
                // A rest asked for before the colour was known did nothing;
                // now that it is known, honour it.
                if self.isResting, self.restingVeil == nil {
                    let veil = self.veil()
                    self.addSubview(veil, positioned: .below, relativeTo: nil)
                    veil.alphaValue = Self.veilStrength
                }
            }
        }
        settlingUntil = CACurrentMediaTime() + 0.7
        ghostty_surface_set_content_scale(surface, config.scale_factor, config.scale_factor)
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0
        applyColorScheme()
        updateSize()
        startDisplayLink()
    }

    /// Where this surface says whether it is on screen.
    ///
    /// Named on the third line of the attach file and, unlike the first two,
    /// read for as long as the client runs. A tab is fitted to its smallest
    /// viewer, and every tab a window has ever shown stays mounted here with a
    /// live client — merely hidden. Without this, a narrow window that visited
    /// a tab once would keep voting on its size forever, throttling a wide
    /// window showing that same tab, for a reason nothing on screen explains.
    private var watchFile: URL?

    /// A private directory holding this surface's attach target, and the file
    /// it will keep answering through.
    private static func makeTargetDirectory(
        workspace: String, tab: UInt32
    ) -> (path: String, watch: URL)? {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-attach", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let watch = base.appendingPathComponent("showing")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try "1".write(to: watch, atomically: true, encoding: .utf8)
            try "\(workspace)\n\(tab)\n\(watch.path)\n".write(
                to: base.appendingPathComponent(".keep-attach"),
                atomically: true,
                encoding: .utf8
            )
            return (base.path, watch)
        } catch {
            return nil
        }
    }

    /// Say whether this surface is on screen, for the client to read.
    ///
    /// Deliberately about layout, not occlusion: a window buried behind
    /// another app still has a real size and comes back in a second, and
    /// dropping its vote every time you switch apps would resize the shell
    /// back and forth for nothing. What counts is being mounted and not
    /// hidden — the state the tab switch flips.
    private func noteShowing() {
        guard let watchFile else { return }
        let showing = window != nil && !isHiddenOrHasHiddenAncestor
        try? (showing ? "1" : "0").write(to: watchFile, atomically: true, encoding: .utf8)
    }

    // MARK: - drawing

    /// The runtime asked for a frame (GHOSTTY_ACTION_RENDER). The first one
    /// is also the proof that this build drives its own drawing, which
    /// retires the free-running display link permanently.
    func runtimeRequestedDraw() {
        guard let surface else { return }
        if !renderDriven {
            renderDriven = true
            Trace.log("render", "\(workspace)/\(tab) render-driven; display link retired")
        }
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        ghostty_surface_draw(surface)
        drawCount += 1
    }

    // MARK: - how often to draw

    /// Frames are cheap to ask for and expensive to make. Nothing else paints
    /// this view — the runtime never asks for a frame in this build, so the
    /// link cannot be retired — but drawing an idle terminal at the display's
    /// own rate costs a tenth of a core to show the same thing 120 times a
    /// second. So the link keeps running and the drawing follows activity:
    /// every frame while something is happening, ten a second when not, which
    /// is still prompt for output and still blinks a cursor.
    ///
    /// "Something is happening" means input from the keyboard or mouse, or the
    /// runtime reporting that the terminal's contents moved.
    private var busyUntil: CFTimeInterval = 0
    private var lastDraw: CFTimeInterval = 0
    /// How long an event keeps the surface at full rate.
    private static let busyFor: CFTimeInterval = 0.75
    /// The idle rate: ten frames a second.
    private static let idleInterval: CFTimeInterval = 0.1

    /// Draw at full rate for a moment, because something just happened.
    func noteActivity() {
        busyUntil = CACurrentMediaTime() + Self.busyFor
    }

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async {
                guard let self, let surface = self.surface else { return }
                let now = CACurrentMediaTime()
                // Every frame while something is happening; a tenth of a
                // second apart when nothing is.
                guard now < self.busyUntil || now - self.lastDraw >= Self.idleInterval
                else { return }
                self.lastDraw = now
                ghostty_surface_draw(surface)
                self.drawCount += 1
            }
            return kCVReturnSuccess
        }
        displayLink = link
        syncDisplayLink()
        startTraceTimer()
    }

    /// Whether anyone can currently see this surface. With one window, being
    /// in a visible window is not enough — most mounted surfaces are hidden.
    private var isEffectivelyVisible: Bool {
        !isHiddenOrHasHiddenAncestor
            && (window?.occlusionState.contains(.visible) ?? false)
    }

    /// The passive backstop: keep the link's running state matched to
    /// visibility. The switch pipeline uses the explicit fast path below
    /// instead of waiting for notifications.
    private func syncDisplayLink() {
        guard let link = displayLink else { return }
        let shouldRun = isEffectivelyVisible && !renderDriven
        if shouldRun {
            if !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
        } else if CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    /// Draw now, without waiting to be told the view is visible. The switch
    /// pipeline calls this while the view is still hidden, so its layer holds
    /// a fresh frame at final geometry before the reveal commits.
    func resumeDrawing() {
        guard let surface else { return }
        flushPendingSize()
        ghostty_surface_set_occlusion(surface, true)
        if !renderDriven, let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
        ghostty_surface_draw(surface)
        drawCount += 1
    }

    /// Stop drawing for a surface that is alive but off screen.
    func suspendDrawing() {
        if let surface { ghostty_surface_set_occlusion(surface, false) }
        guard let link = displayLink, CVDisplayLinkIsRunning(link) else { return }
        CVDisplayLinkStop(link)
    }

    /// AppKit calls these on every descendant when an ancestor's isHidden
    /// flips — the automatic half of the visibility policy. The pipeline's
    /// explicit resume/suspend still runs first; these make the invariant
    /// hold no matter who toggled what.
    override func viewDidHide() {
        super.viewDidHide()
        suspendDrawing()
        noteShowing()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        noteShowing()
        flushPendingSize()
        if let surface {
            ghostty_surface_set_occlusion(surface, true)
            ghostty_surface_draw(surface)
        }
        syncDisplayLink()
    }

    private func observeOcclusion() {
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else {
            syncDisplayLink()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDisplayLink() }
        }
        syncDisplayLink()
    }

    /// Report the draw rate once a second while tracing. Silence is the
    /// expected state for anything hidden.
    // MARK: - scrolling to a line

    /// Put a line of history on screen, counted back from the newest.
    ///
    /// Ghostty exposes scrolling as keybind actions rather than as calls, so
    /// this asks for the actions by the names a config would use.
    ///
    /// It asks twice. A pane opened by a search result is mounted by the same
    /// switch that asks for the scroll, and its history is still arriving over
    /// the socket — the snapshot lands the viewport back at the bottom after
    /// the first attempt. Asking again once it has settled costs nothing when
    /// the first attempt already worked, because the target is the same place.
    func scrollBack(lines: Int) {
        apply(scrollBack: lines)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.apply(scrollBack: lines)
        }
    }

    private func apply(scrollBack lines: Int) {
        guard surface != nil else {
            Trace.log("scroll", "\(workspace)/\(tab) asked for \(lines) with no surface")
            return
        }
        // From the bottom, always: the oldest end of a history is where the
        // daemon's copy and this one disagree, because a terminal trims it.
        perform("scroll_to_bottom")
        // Four rows short of the line, so it arrives with what follows it
        // rather than pinned to the last row of the screen. A line already
        // near the end simply stays where the bottom is.
        let back = max(0, lines - 4)
        guard back > 0 else { return }
        perform("scroll_page_lines:-\(back)")
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        guard let surface else { return false }
        let done = action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
        Trace.log("scroll", "\(workspace)/\(tab) \(action) done=\(done)")
        return done
    }

    private func startTraceTimer() {
        guard Trace.enabled else { return }
        traceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let drawn = self.drawCount
                self.drawCount = 0
                let visible = self.isEffectivelyVisible
                let running = self.displayLink.map { CVDisplayLinkIsRunning($0) } ?? false
                guard drawn > 0 || (visible && running) else { return }
                Trace.log("render", "\(self.workspace)/\(self.tab) fps=\(drawn) "
                    + "visible=\(visible) mode=\(self.renderDriven ? "on-demand" : "link")")
            }
        }
    }

    // MARK: - geometry

    /// Push the view's size to the session — deduplicated, and deferred
    /// entirely while hidden.
    private func updateSize() {
        guard let surface else { return }
        // libghostty wants the framebuffer size, so convert rather than
        // multiplying by a guessed scale.
        let backing = convertToBacking(bounds).size
        guard backing != sentSize || pendingSize != nil else { return }
        if isHiddenOrHasHiddenAncestor {
            pendingSize = backing
            return
        }
        pendingSize = nil
        sentSize = backing
        Trace.log("layout", "\(workspace)/\(tab) size \(Int(backing.width))x\(Int(backing.height))")
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, backing.width)),
            UInt32(max(1, backing.height))
        )
        reportGrid()
    }

    // MARK: - being moved

    private lazy var grip: GripView = {
        let grip = GripView(frame: .zero)
        grip.isHidden = true
        grip.onEvent = { [weak self] event, phase in self?.onGripEvent?(event, phase) }
        addSubview(grip)
        return grip
    }()

    /// Whether this pane can be picked up at all. A pane with nowhere to go —
    /// the only one in its tab — shows no handle.
    var isDraggable = false {
        didSet {
            guard isDraggable != oldValue else { return }
            grip.isHidden = !isDraggable
            needsLayout = true
        }
    }

    var onGripEvent: ((NSEvent, GripView.Phase) -> Void)?

    private func positionGrip() {
        guard isDraggable else { return }
        let size = NSSize(width: 44, height: 14)
        grip.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: bounds.height - size.height - 4,
            width: size.width,
            height: size.height)
    }

    // MARK: - resting

    /// A sheet of the terminal's own background colour, laid over the pane
    /// that does not have the keyboard.
    ///
    /// Fading the view itself was the obvious thing and the wrong one: this
    /// window is translucent, so less opacity means more of what is behind it
    /// comes through, and a dimmed pane came out lighter than a lit one. The
    /// background is already this colour, so a veil of it changes nothing
    /// there and takes the text back — which is the part that was meant to
    /// step back in the first place.
    private var restingVeil: VeilView?

    private func veil() -> VeilView {
        if let restingVeil { return restingVeil }
        let veil = VeilView(frame: bounds)
        veil.wantsLayer = true
        veil.autoresizingMask = [.width, .height]
        veil.alphaValue = 0
        addSubview(veil)
        restingVeil = veil
        paintVeil()
        return veil
    }

    /// The veil is the terminal's own background colour, and that colour is
    /// not known at launch — the config is read after the first surfaces are
    /// already up. A veil painted then came out black, which is not a veil
    /// but a shadow, and it stayed that way until something happened to
    /// repaint it. So it is repainted when the colour arrives.
    private func paintVeil() {
        guard let restingVeil, let background = GhosttyApp.shared.terminalBackground else {
            return
        }
        restingVeil.layer?.backgroundColor = background.cgColor
    }

    /// How much of the text a pane keeps when the keyboard is elsewhere.
    private static let veilStrength: CGFloat = 0.5

    var isResting = false {
        didSet {
            guard isResting != oldValue else { return }
            // Nothing to rest under until the terminal's colour is known: a
            // veil of no colour is a black one, and a pane that has merely
            // lost the keyboard should not go dark.
            guard GhosttyApp.shared.terminalBackground != nil || restingVeil != nil else {
                return
            }
            let veil = veil()
            paintVeil()
            // Kept at the bottom of the subviews, which is still above the
            // terminal: the handle and the size chip stay legible over it.
            addSubview(veil, positioned: .below, relativeTo: nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                veil.animator().alphaValue = isResting ? Self.veilStrength : 0
            }
        }
    }

    // MARK: - saying how big the pane is

    private lazy var sizeBadge: SizeBadgeView = {
        let badge = SizeBadgeView(frame: .zero)
        badge.alphaValue = 0
        addSubview(badge)
        return badge
    }()
    /// The grid last seen. Nil until the first size, because the size a pane
    /// opens at is not a resize and nobody asked to be told it.
    private var lastGrid: (cols: UInt16, rows: UInt16)?
    private var badgeHide: DispatchWorkItem?
    /// Until when a change of grid is settling rather than being asked for.
    ///
    /// Mounting a pane walks through two or three sizes as constraints
    /// resolve, and revealing a hidden one takes the size it slept through.
    /// Neither is somebody dragging an edge, and announcing them flashes the
    /// chip at a person who did nothing.
    private var settlingUntil: CFTimeInterval = 0

    /// Show the grid, if setting the pixel size actually changed it.
    ///
    /// Points are not the unit that matters: dragging a divider a few pixels
    /// often leaves the columns and rows exactly as they were, and saying so
    /// then would be noise. Only a real change speaks.
    private func reportGrid() {
        guard let surface, !isHiddenOrHasHiddenAncestor else { return }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return }
        let grid = (cols: size.columns, rows: size.rows)
        Trace.log("layout", "\(workspace)/\(tab) grid \(grid.cols)x\(grid.rows)")
        defer { lastGrid = grid }
        guard let previous = lastGrid else { return }
        guard previous != grid else { return }
        guard CACurrentMediaTime() > settlingUntil else { return }

        sizeBadge.show("\(grid.cols) × \(grid.rows)")
        sizeBadge.frame.size = sizeBadge.fittingSize
        sizeBadge.frame.origin = NSPoint(
            x: ((bounds.width - sizeBadge.frame.width) / 2).rounded(),
            y: ((bounds.height - sizeBadge.frame.height) / 2).rounded())
        badgeHide?.cancel()
        sizeBadge.animator().alphaValue = 1

        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self.sizeBadge.animator().alphaValue = 0
            }
        }
        badgeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hide)
    }

    private func flushPendingSize() {
        guard let surface, let pending = pendingSize else { return }
        pendingSize = nil
        sentSize = pending
        Trace.log("layout", "\(workspace)/\(tab) size \(Int(pending.width))x\(Int(pending.height)) (deferred)")
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, pending.width)),
            UInt32(max(1, pending.height))
        )
        // A pane catching up after being revealed is not being resized in
        // front of anyone; it takes the new grid without announcing it.
        settlingUntil = CACurrentMediaTime() + 0.7
        reportGrid()
    }

    /// Keep the layer from being rescaled by the compositor: we render at the
    /// display's density and Core Animation must know it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        if let surface {
            let scale = window.backingScaleFactor
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        sentSize = nil   // scale changed: the same points are new pixels
        updateSize()
    }

    /// Tell libghostty whether we are dark or light, or a `dark:`/`light:`
    /// theme pair renders its wrong half.
    private func applyColorScheme() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ghostty_surface_set_color_scheme(
            surface,
            dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColorScheme()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }

    override func layout() {
        super.layout()
        // setFrameSize alone misses the first pass; the dedupe above makes
        // the overlap free.
        updateSize()
        positionGrip()
    }

    // MARK: - focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            noteFocus()
            onFocusGained?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface { ghostty_surface_set_focus(surface, false) }
        return resigned
    }

    /// Tell the terminal whether it has the keyboard, meaning the keyboard of
    /// the machine and not of its own window.
    ///
    /// Every window has a first responder, all the time, whether or not that
    /// window is the one you are typing in. Reporting focus on becoming one
    /// was right while there was a single window and wrong the moment there
    /// are two: a tab open in both would have two terminals each believing
    /// they were focused — two cursors blinking, and two answers to a program
    /// that asked to be told when focus moves.
    func noteFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.isKeyWindow == true && isFirstResponderHere)
    }

    private var isFirstResponderHere: Bool {
        window?.firstResponder === self
    }

    // MARK: - input

    /// Mouse-move reports go to the surface under the pointer, not to
    /// whichever surface last held the keyboard.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// The tab this pane is laid out in, found by walking up.
    ///
    /// Not held as a reference: a pane is moved between hosts when somebody
    /// carries it into another tab, and a stored answer would be the previous
    /// tab's the moment that happened.
    var tabHost: TabHostView? {
        var view: NSView? = superview
        while let current = view {
            if let host = current as? TabHostView { return host }
            view = current.superview
        }
        return nil
    }

    /// A key press, offered to the input system before the terminal.
    ///
    /// The terminal used to be handed every press as it came, which is right
    /// for a key and wrong for a letter somebody is still composing: on a
    /// layout with dead keys, ´ followed by e is one character, and only the
    /// input system knows that. Asked nothing, it put nothing together — the
    /// accent was dropped and the e arrived bare, so "é" typed as "e" and
    /// "não" as "nao". This is the path Ghostty's own view takes with the
    /// same library.
    ///
    /// On Brazilian - Pro the dead keys are not only accents: ' " ` ~ and ^
    /// all wait for the next key, so a closing quote is marked text right up
    /// until whatever is pressed after it. Everything below that talks about
    /// "the accent" is just as often the quote at the end of a command line.
    ///
    /// A chord is still a key. Control and command make shortcuts, not text,
    /// and option is alt here (see `text(of:)`), so a press holding any of
    /// them skips composition and is sent the way it always was — once
    /// whatever was waiting has been committed, the way AppKit's own text
    /// views commit it. The exception is an input method in the middle of a
    /// word: its editing keys (control-h, control-k) are its own, and a
    /// control chord goes to it. Option and command chords never do — through
    /// the key bindings option-b would type ∫ instead of reaching the shell
    /// as alt-b.
    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        if Self.isChord(event), !(markedText.length > 0 && inputMethodActive && Self.isControlChord(event)) {
            let pending = markedText.length > 0
            commitComposition()
            // After a dead key the event still carries it: ⌘V arrives as "'v",
            // which no menu item matches and which would type the quote a
            // second time. So the key is asked again, from its key code,
            // without the dead key — option still taken out, as `text(of:)`
            // takes it out. Only a key that carries text at all: control-space
            // is a NUL, and asked again it would come back as a space.
            let text = pending && !Self.text(of: event).isEmpty
                ? event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option)) ?? ""
                : nil
            send(event, action: GHOSTTY_ACTION_PRESS, text: text)
            return
        }

        let markedBefore = markedText.string
        let composingBefore = !markedBefore.isEmpty
        keyTextAccumulator = []
        keyCommands = []
        defer {
            keyTextAccumulator = nil
            keyCommands = nil
        }
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: composingBefore)

        // Composing either because something is marked now, or because it
        // was and this press is what ended it.
        let composing = markedText.length > 0 || composingBefore
        var committed = (keyTextAccumulator ?? [])
            .filter { !Self.isComposingControl($0, composing: composing) }
        let commands = keyCommands ?? []

        if composingBefore, !committed.isEmpty {
            // A control chord an input method let through after committing
            // its word comes back from the key bindings as its own character —
            // control-1 as "1", and control-shift-9 as "9", since control
            // keeps shift from applying. That is the chord, not text, and it
            // is sent as the chord, carrying that character as it would with
            // nothing composed: the legacy and modifyOtherKeys encoders need
            // it to encode control-comma at all.
            var handedBack = !commands.isEmpty
            var replayText = ""
            if Self.isChord(event), committed.count > 1, let last = committed.last,
               [event.charactersIgnoringModifiers,
                event.characters(byApplyingModifiers: event.modifierFlags)].contains(last) {
                committed.removeLast()
                handedBack = true
                replayText = last
            }
            // Backspace taking a dead key back. The layout has no cancel for
            // it: AppKit commits the accent and then asks for deleteBackward:,
            // and a text view inserting one and deleting the other ends with
            // neither. So does this, without sending either — a quote handed
            // to the program and then a DEL is not the same as nothing, and a
            // ˜ or ˆ is more than one byte for the program to take back.
            if committed == [markedBefore], commands.contains(Self.deleteBackward) {
                return
            }
            // The press finished a composition: "é" out of ´ and e, which is
            // text with no key behind it, and the e is spent. A key that
            // merely ended it — return, tab, escape, an arrow — is not: AppKit
            // commits the accent and hands the key back as a command, and the
            // terminal gets the key after the accent, as a text view would.
            for text in committed { sendCommitted(text) }
            if replaysAfterCommit(event, handedBack: handedBack) {
                // Not the event's characters: those are the accent and the
                // key together ("'\r"), and the accent is sent.
                send(event, action: GHOSTTY_ACTION_PRESS, text: replayText)
            }
            return
        }
        if !committed.isEmpty {
            for text in committed {
                send(event, action: GHOSTTY_ACTION_PRESS, text: text)
            }
            return
        }
        if Self.isComposingControl(event.characters, composing: composing) { return }
        // Nothing committed: an ordinary key (return, the arrows, backspace),
        // or the dead key itself, which libghostty is told is composing so
        // that it encodes nothing for it.
        send(event, action: GHOSTTY_ACTION_PRESS, composing: composing)
    }

    override func keyUp(with event: NSEvent) {
        send(event, action: GHOSTTY_ACTION_RELEASE)
    }

    /// A press that holds control, option or command.
    private static func isChord(_ event: NSEvent) -> Bool {
        !event.modifierFlags.isDisjoint(with: [.control, .option, .command])
    }

    /// A chord of control alone: the only kind an input method has uses for.
    private static func isControlChord(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.control)
            && event.modifierFlags.isDisjoint(with: [.option, .command])
    }

    private static let deleteBackward = #selector(NSStandardKeyBindingResponding.deleteBackward(_:))

    /// Whether a key that ended a composition should also act as itself.
    ///
    /// When AppKit handed it back, yes: that is the input system saying the
    /// key was not spent. An input method confirming a word on return asks
    /// for no command, and its return is not replayed. The arrows are
    /// Ghostty's rule and replay regardless — except an unmodified left
    /// arrow after an input method commits, because AppKit already leaves
    /// the caret in place after Korean input methods commit. After a dead
    /// key it moves.
    private func replaysAfterCommit(_ event: NSEvent, handedBack: Bool) -> Bool {
        let modified = !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        if event.keyCode == 123, !modified, inputMethodActive { return false }
        if handedBack { return true }
        switch event.keyCode {
        case 124, 125, 126: return true  // right, down, up
        case 123: return modified  // left
        default: return false
        }
    }

    /// Whether the text being composed comes from an input method (Japanese,
    /// Chinese, Korean) rather than a keyboard layout's dead keys. The two
    /// want different things from a chord and from a left arrow.
    private var inputMethodActive: Bool {
        guard let source = inputContext?.selectedKeyboardInputSource else { return false }
        return !source.contains(".keylayout.")
    }

    /// A lone control character that arrived while composing. It belongs to
    /// the input method, and passing it on would reach the program as a
    /// keystroke nobody meant for it.
    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first, scalars.count == 1 else { return false }
        return scalar.value < 0x20
    }

    /// Text the input system committed, sent as typed input rather than as
    /// a paste. It has no key behind it, so none is claimed: no key code, no
    /// modifiers.
    private func sendCommitted(_ text: String) {
        noteActivity()
        guard let surface, !text.isEmpty else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = 0
        key.unshifted_codepoint = 0
        key.composing = false
        let taken = text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
        Trace.log("key", "commit \(text.unicodeScalars.count) scalar(s) \(taken ? "taken" : "IGNORED")")
    }

    /// Tell libghostty what is being composed, so it draws it at the cursor.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Finish whatever is being composed as it stands, before something that
    /// is not text — a chord, a paste — lands after it.
    ///
    /// What was waiting is committed, not dropped: on this layout it is as
    /// likely to be the closing quote of `echo "hi"` as an accent, and ⌃A to
    /// edit that line must not take the quote with it. AppKit's text views
    /// commit it too.
    ///
    /// The input context has to be reset afterwards, not just told to discard.
    /// `discardMarkedText` leaves a keyboard layout's dead key stuck in it:
    /// every later key is swallowed without a single callback, and the pane
    /// goes back to typing "e" for "é" until focus leaves it. Deactivating
    /// and reactivating clears that. An input method may commit its own text
    /// on the way out; if it does, that is what is sent, and only once.
    private func commitComposition() {
        guard markedText.length > 0 else { return }
        let pending = markedText.string
        markedText = NSMutableAttributedString()
        keyTextAccumulator = []
        inputContext?.discardMarkedText()
        inputContext?.deactivate()
        inputContext?.activate()
        let flushed = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        markedText = NSMutableAttributedString()
        syncPreedit()
        sendCommitted(flushed.isEmpty ? pending : flushed.joined())
    }

    private func send(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        text explicit: String? = nil,
        composing: Bool = false
    ) {
        noteActivity()
        guard let surface else { return }
        let text = explicit.map { Self.printable($0) } ?? Self.text(of: event)
        var key = ghostty_input_key_s()
        key.action = action
        let mods = Self.mods(from: event.modifierFlags)
        key.mods = mods
        key.consumed_mods = Self.consumedMods(of: event)
        key.keycode = UInt32(event.keyCode)
        // The character this key makes with nothing held down, and only if
        // that is a character at all.
        //
        // Asked for with no modifiers rather than read from
        // `charactersIgnoringModifiers`, which is not the same question: with
        // control held that property answers with the control code, so ctrl-h
        // reported itself as 8 where the kitty protocol wants 104 — the key
        // "h", which is what was pressed.
        //
        // And a key that makes no character says so by saying nothing. The
        // platform answers for backspace with U+007F, which is the byte that
        // key sends, not a character it types — and the terminal already
        // knows backspace from its key code. Passing the byte on as though it
        // were the key's letter is the one thing this event carried that a
        // working one does not.
        key.unshifted_codepoint = Self.unshiftedCodepoint(of: event)
        key.composing = composing

        // What the terminal made of it, which is one bit and the only account
        // there is of a key that produced nothing: true means something
        // claimed the press — a keybinding, usually — and false means the
        // encoder was handed the key and wrote no bytes for it. From the far
        // end the two are identical, and they want opposite repairs.
        let taken: Bool
        if text.isEmpty {
            key.text = nil
            taken = ghostty_surface_key(surface, key)
        } else {
            taken = text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        Trace.log(
            "key",
            "\(action == GHOSTTY_ACTION_PRESS ? "down" : "up  ") code=\(event.keyCode)"
                + " mods=\(mods.rawValue) carried=\(text.isEmpty ? "nothing" : "text")"
                + " \(taken ? "taken" : "IGNORED")")
    }

    /// The text a key press should put into the terminal, if any.
    ///
    /// Three things are not text, and each was found by reading what Ghostty
    /// itself does with the same library.
    ///
    /// A function key is reported with a codepoint out of the private use
    /// area — U+F702 for the left arrow, and so on through the function row,
    /// home and end. Those are the platform's markers for "this key", not
    /// anything a person typed, and handing one on gives the terminal a
    /// character to print beside the escape sequence the key actually meant.
    ///
    /// A control character is the terminal's to make. libghostty encodes
    /// those itself, from the physical key and its modifiers, precisely so
    /// that both survive into protocols that want to report them separately —
    /// hand it the finished byte instead and the key is spent.
    ///
    /// And a press with option held is composed by AppKit before anyone sees
    /// it: option-slash arrives as "÷", because that is what option does on a
    /// Mac keyboard. It is not what it does here. So the key is asked again
    /// with option taken out of the modifiers, which is the character the
    /// chord is actually about, rather than being asked to ignore *all* of
    /// them — shift is still shift, and a capital is still a capital.
    private static func text(of event: NSEvent) -> String {
        // Only a press with option held is asked again. `byApplyingModifiers`
        // re-derives the character from the key code and the layout, which is
        // the right answer for a key somebody pressed and the wrong one for
        // an event that carries text without a key behind it — those arrive
        // with a key code of zero, which is the letter "a", so every
        // character a text expander or dictation sent became one. The plain
        // path keeps taking the event at its word.
        let source: String?
        if event.modifierFlags.contains(.option) {
            var translation = event.modifierFlags
            translation.remove(.option)
            source = event.characters(byApplyingModifiers: translation)
        } else {
            source = event.characters
        }
        return printable(source)
    }

    /// The characters, unless they are one of the things above that is not
    /// text: a function key's private-use marker or a control character.
    private static func printable(_ characters: String?) -> String {
        guard let characters, let first = characters.unicodeScalars.first
        else { return "" }
        if (0xF700...0xF8FF).contains(first.value) { return "" }
        if first.value < 0x20 || first.value == 0x7F { return "" }
        return characters
    }

    /// The character a key makes on its own, or nothing if it makes none.
    private static func unshiftedCodepoint(of event: NSEvent) -> UInt32 {
        guard let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        else { return 0 }
        if scalar.value < 0x20 || scalar.value == 0x7F { return 0 }
        if (0xF700...0xF8FF).contains(scalar.value) { return 0 }
        return scalar.value
    }

    /// Which modifiers went into making the character, as opposed to being
    /// held alongside it.
    ///
    /// macOS does not say, so this is the heuristic Ghostty has used for
    /// years: control and command never contribute to a character, and
    /// whatever is left did. Option comes out first because here it is alt —
    /// a modifier, not a compose key — so it contributed nothing either.
    ///
    /// Dead weight for a key carrying no text, and decisive for one that
    /// does. libghostty subtracts these from the modifiers before encoding,
    /// so a shift never declared consumed stays live, and shift-slash — which
    /// is simply "?" — reaches the program as a shifted slash rather than as
    /// the character that was typed. A plain shell shrugs that off; a program
    /// using the kitty keyboard protocol takes it at its word, and the
    /// question mark never arrives.
    ///
    /// Declaring it wrongly is how this broke before: the whole modifier set
    /// was handed over, which cancels modifiers that really were held and
    /// left backspace, escape and the arrows arriving as other keys.
    ///
    /// And shift is only spent on the keys it actually changes. It makes "?"
    /// out of "/", so on that key it is spent and must not be reported twice.
    /// It makes nothing of tab — the key types a tab either way — so on that
    /// one it was merely held, and reporting it as spent is how shift-tab
    /// reached a program in kitty mode as a plain tab: whatever cycles
    /// forwards on tab and backwards on shift-tab simply went forwards, or
    /// did nothing at all, with no way from inside the program to tell why.
    private static func consumedMods(of event: NSEvent) -> ghostty_input_mods_e {
        var translation = event.modifierFlags
        translation.remove(.option)
        translation.remove(.control)
        translation.remove(.command)
        if translation.contains(.shift), !shiftChangedTheCharacter(event) {
            translation.remove(.shift)
        }
        return mods(from: translation)
    }

    /// Whether holding shift made this key type something else.
    ///
    /// Asked of the keyboard layout rather than assumed: on one layout a key
    /// shifts into another character and on the next it does not, and the
    /// answer decides whether the program is told shift was held.
    private static func shiftChangedTheCharacter(_ event: NSEvent) -> Bool {
        guard let typed = event.characters(byApplyingModifiers: .shift),
              let plain = event.characters(byApplyingModifiers: [])
        else { return false }
        return typed != plain
    }

    private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(raw)
    }

    // MARK: - selecting a column

    /// Whether the chord that means "select a column" is being held.
    static func isColumnChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && flags.contains(.shift)
            && !flags.contains(.command) && !flags.contains(.control)
    }

    /// The modifiers a mouse event carries into the terminal.
    ///
    /// Option and shift together are this app's gesture for selecting a
    /// column, and the terminal's own gesture for it is option. Shift is
    /// dropped on the way rather than passed along, because to a terminal
    /// shift on a drag means "widen what is already selected" — the two would
    /// be asking for different things at once.
    private static func mouseMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        guard isColumnChord(flags) else { return mods(from: flags) }
        return ghostty_input_mods_e(GHOSTTY_MODS_ALT.rawValue)
    }

    /// A crosshair while the chord is held, an I-beam the rest of the time.
    ///
    /// The pointer is the only thing that can say a different kind of
    /// selection is about to happen, since nothing is on screen yet when the
    /// keys go down.
    override func resetCursorRects() {
        super.resetCursorRects()
        let held = NSEvent.modifierFlags
        addCursorRect(bounds, cursor: Self.isColumnChord(held) ? .crosshair : .iBeam)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let chord = Self.isColumnChord(event.modifierFlags)
        guard chord != showingColumnCursor else { return }
        showingColumnCursor = chord
        window?.invalidateCursorRects(for: self)
        // The rects only take effect the next time the pointer moves over
        // them, and the pointer is not moving: the person is holding keys and
        // waiting to see whether anything changed.
        (chord ? NSCursor.crosshair : NSCursor.iBeam).set()
    }

    override func mouseDown(with event: NSEvent) {
        noteActivity()
        window?.makeFirstResponder(self)
        // Where before whether. A press in a window that was not key arrives
        // without any of the tracked movement that would have said where the
        // pointer is, and a press at the wrong place selects from there.
        reportMouse(event)
        mouseButton(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        noteActivity()
        reportMouse(event)
        mouseButton(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        traceSelection()
    }

    /// What ended up selected, for the test that asks whether a drag with a
    /// modifier selects a column or a run of lines.
    private func traceSelection() {
        guard Trace.enabled, let surface, ghostty_surface_has_selection(surface) else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), let value = text.text else { return }
        let selected = String(cString: value).replacingOccurrences(of: "\n", with: "|")
        Trace.log("select", selected)
        ghostty_surface_free_text(surface, &text)
    }

    /// Dragging is how a selection is made, and AppKit does not call it
    /// moving: while a button is down every motion arrives here and none
    /// arrives at `mouseMoved`. Without this the terminal saw a press and a
    /// release in the same place and selected nothing.
    override func mouseDragged(with event: NSEvent) {
        noteActivity()
        reportMouse(event)
    }

    private func mouseButton(
        _ event: NSEvent,
        action: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, action, button, Self.mouseMods(from: event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        reportMouse(event)
    }

    private func reportMouse(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface, p.x, bounds.height - p.y, Self.mouseMods(from: event.modifierFlags))
    }

    // MARK: - where this shell is

    /// The directory the shell in this pane is in, as it last announced it.
    ///
    /// Shells say so with OSC 7 on each prompt, and the terminal reports it
    /// on. Nil until the first prompt, and stale by exactly as long as a
    /// program that changes directory without printing a prompt runs.
    private(set) var currentDirectory: String?

    func noteTitle(_ title: String) {
        guard title != lastTitle else { return }
        lastTitle = title
        onTitle?(title)
    }

    /// What was last reported, so a program repainting the same title does
    /// not walk the whole model up to the tab strip to say nothing.
    private var lastTitle: String?

    func noteDirectory(_ raw: String) {
        // Reported as a file URL — file://host/path — and wanted as a path.
        let path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : raw
        guard !path.isEmpty, path != currentDirectory else { return }
        currentDirectory = path
        Trace.log("pwd", "\(workspace)/\(tab) \(path)")
    }

    // MARK: - the standard editing commands

    /// Copy, paste and select-all arrive through the responder chain from the
    /// Edit menu, which is where a Mac app is expected to keep them. Each is
    /// the ghostty binding of the same name: the terminal owns the selection
    /// and the scrollback, so it is the only thing that can answer.
    @objc func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) {
        // ⌘V is the menu's, so keyDown never sees it: a quote left waiting
        // would otherwise land after the pasted text instead of before it.
        commitComposition()
        perform("paste_from_clipboard")
    }
    @objc override func selectAll(_ sender: Any?) { perform("select_all") }

    // MARK: - files dropped on the terminal

    /// A drag of files over this pane is offered a copy; anything else — the
    /// sidebar's own rows, text, a link — is refused, so letting go of it
    /// here types nothing. See `DroppedFiles`.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DroppedFiles.canTake(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DroppedFiles.canTake(sender.draggingPasteboard) ? .copy : []
    }

    /// Type the paths of the files let go here, into this pane — the one under
    /// the pointer, which need not be the one with the keyboard.
    ///
    /// Files that exist are typed at once. Files an app only promises are
    /// written first, each to a folder of its own under the temporary
    /// directory, and typed as they arrive.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = DroppedFiles.fileURLs(on: pasteboard)
        if !urls.isEmpty {
            typePaths(urls.map(\.path))
            return true
        }
        let promises = DroppedFiles.promises(on: pasteboard)
        guard !promises.isEmpty, let folder = try? DroppedFiles.promiseFolder() else { return false }
        for promise in promises {
            promise.receivePromisedFiles(
                atDestination: folder, options: [:], operationQueue: Self.promiseQueue
            ) { [weak self] url, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        Trace.log("drop", "\(self.workspace)/\(self.tab) promise failed: \(error)")
                        NSSound.beep()
                        return
                    }
                    self.typePaths([url.path])
                }
            }
        }
        return true
    }

    /// Where promised files are written. Off the main thread: an app may take
    /// its time to write a large one.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Paste the paths, with a space after them.
    ///
    /// Pasted, not typed: a program that asked for bracketed paste gets them
    /// framed as one — Claude Code reads a pasted image path as the image —
    /// and a shell runs nothing on the way in.
    ///
    /// The space is Terminal's, so what is typed next does not run into the
    /// last path, and it goes inside the paste. Typed after it, it raced
    /// Claude Code, which reads a pasted image before it puts the image in
    /// the prompt: the space landed first, and the image after it. A space
    /// pasted after an image path is dropped with the path, and one after any
    /// other path stays.
    private func typePaths(_ paths: [String]) {
        guard let surface, !paths.isEmpty else { return }
        // A quote waiting on a dead key belongs before the paths, as before a
        // ⌘V.
        commitComposition()
        noteActivity()
        let text = DroppedFiles.text(for: paths) + " "
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
        Trace.log("drop", "\(workspace)/\(tab) \(paths.count) path(s), \(text.utf8.count) byte(s)")
    }

    // MARK: - clipboard

    /// Hand back what the terminal asked for.
    ///
    /// `state` is the runtime's own token for the request; it means nothing
    /// here and must travel back untouched. Passing `confirmed` as false lets
    /// ghostty judge the text first -- text with line breaks pasted outside
    /// bracketed paste runs the moment it lands -- and ask again through
    /// `confirmPaste` if it does not like what it sees.
    func completeClipboardRequest(
        _ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool
    ) {
        guard let surface else { return }
        text.withCString {
            ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed)
        }
    }

    /// Ask before pasting something that would run itself.
    func confirmPaste(_ text: String, state: UnsafeMutableRawPointer?) {
        let alert = NSAlert()
        alert.messageText = "Paste this?"
        alert.informativeText = "What you are pasting has line breaks in it, "
            + "and the program running here reads those as return: it will run "
            + "as soon as it lands.\n\n" + String(text.prefix(400))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        // A sheet on this surface's own window: the question is about this
        // terminal, and the other window has no business being frozen by it.
        // The answer is allowed to arrive later — this is already a turn of
        // the run loop after the runtime asked, and the request stays open
        // until it is completed.
        guard let window else {
            let go = alert.runModal() == .alertFirstButtonReturn
            return completeClipboardRequest(go ? text : "", state: state, confirmed: true)
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let go = response == .alertFirstButtonReturn
            self?.completeClipboardRequest(go ? text : "", state: state, confirmed: true)
        }
    }

    /// Scrolling, which is also how the scrollback becomes reachable at all:
    /// the surface keeps the history, and until these events were forwarded
    /// there was simply no way to move the viewport into it.
    override func scrollWheel(with event: NSEvent) {
        noteActivity()
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY

        // `ghostty_input_scroll_mods_t` is a packed byte the header declines
        // to declare (see its comment at the typedef): bit 0 says the deltas
        // are precise — a trackpad reporting points rather than lines — and
        // bits 1-3 carry the momentum phase, which the renderer needs to tell
        // a flick from a drag.
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            mods = 1
            var momentum: ghostty_input_mouse_momentum_e
            switch event.momentumPhase {
            case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
            case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
            case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
            case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
            case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
            case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
            default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
            }
            mods |= Int32(momentum.rawValue) << 1
        } else {
            // A wheel reports lines; the renderer works in points.
            x *= 10
            y *= 10
        }

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }
}

// MARK: - composing text

/// What the input system needs from a view before it will compose for it.
///
/// Without this conformance `interpretKeyEvents` has nobody to put a dead
/// key's accent on or to hand the finished "é" to, and the view has no input
/// context at all. Adapted from Ghostty's own surface view, less what Keep
/// does not have: quick look, services and a selection the input system can
/// read back.
extension TerminalSurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            return
        }
        // Outside a key press — the layout changed while an accent was
        // waiting — nothing else is going to show it, so show it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the candidate window and the dictation indicator go: at the
    /// cursor, which libghostty knows and the view does not.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // A range with nothing in it is a caret, and a caret has no width —
        // the dictation indicator starts wherever this rectangle does.
        if range.length == 0 { width = 0 }
        // libghostty counts down from the top; AppKit counts up from the bottom.
        let inView = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        let inWindow = convert(inView, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }
        // Whatever was being composed is finished the moment text arrives.
        unmarkText()
        // During a key press the press sends it, knowing which key it was.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Dictation, the character viewer, an input method committing on its
        // own time: typed input all the same, never a paste.
        sendCommitted(text)
    }

    /// Commands the key bindings map a key to — insertNewline:, moveLeft:,
    /// deleteBackward: — are not carried out here: the terminal gets the key
    /// itself from `keyDown` and knows what it means. They are only noted, so
    /// `keyDown` can tell a key AppKit handed back from one it spent. Doing
    /// nothing else also keeps AppKit from beeping at a command nobody
    /// answered.
    override func doCommand(by selector: Selector) {
        keyCommands?.append(selector)
    }
}

// MARK: - the size, while it is changing

/// A chip in the middle of a pane saying how many cells it holds.
///
/// A terminal's size is in columns and rows, not points, and a drag that
/// changes the window by a few pixels may change the grid by none — which is
/// the thing worth showing while you drag: what the program inside will
/// actually be given.
private final class SizeBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// It is a readout, not a control: the terminal underneath keeps the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String) {
        label.stringValue = text
        needsLayout = true
    }
}

/// The veil never takes a click: it sits over a terminal.
private final class VeilView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The handle a pane is moved by.
///
/// Three dots at the top of the pane, in the place a title bar would be if a
/// pane had one. It is the only part of a terminal that is not the terminal:
/// everywhere else the mouse belongs to the program inside, so a pane cannot
/// be picked up by its middle without taking selection away.
///
/// Made of the same thing as the chrome's other controls — untinted glass at
/// rest, which refracts into a quiet well, and tinted under the pointer.
final class GripView: NSView {
    var onEvent: ((NSEvent, Phase) -> Void)?
    private let ground: NSView = Glass.lozenge(cornerRadius: 7) ?? NSView()
    private let isGlass = Glass.isAvailable
    private let dots = DotsView()
    private var hovered = false { didSet { retint() } }
    private var dragging = false { didSet { retint() } }

    enum Phase { case began, moved, ended }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ground.wantsLayer = true
        if !isGlass { ground.layer?.cornerCurve = .continuous }
        addSubview(ground)
        addSubview(dots)
        retint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        ground.frame = bounds
        dots.frame = bounds
        let radius = bounds.height / 2
        if isGlass {
            Glass.setCornerRadius(ground, radius)
        } else {
            ground.layer?.cornerRadius = radius
        }
    }

    private func retint() {
        let palette = TabStripView.Palette.current
        if isGlass {
            Glass.tint(ground, hovered || dragging ? palette.glassTint : nil)
        } else {
            let strength: CGFloat = dragging ? 0.16 : (hovered ? 0.12 : 0.06)
            ground.layer?.backgroundColor = NSColor.white
                .withAlphaComponent(strength).cgColor
        }
        dots.strength = dragging ? 0.95 : (hovered ? 0.8 : 0.4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        onEvent?(event, .began)
        // The gesture is run from a nested event loop above this view, which
        // keeps every event from here on; this view will not hear the mouse
        // go up, so it stops looking dragged when the loop returns.
        dragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// The three dots, over whatever ground the grip is standing on.
private final class DotsView: NSView {
    var strength: CGFloat = 0.4 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(strength).setFill()
        let dot: CGFloat = 3
        let gap: CGFloat = 5
        let total = dot * 3 + gap * 2
        var x = ((bounds.width - total) / 2).rounded()
        let y = ((bounds.height - dot) / 2).rounded()
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            x += dot + gap
        }
    }
}
