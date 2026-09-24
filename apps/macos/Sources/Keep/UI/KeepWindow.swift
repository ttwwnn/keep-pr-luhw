import AppKit
import GhosttyKit

/// Native unified chrome with a ClearMic-style flat leading panel.
///
/// The tracking separator keeps the toolbar boundary aligned with the split
/// while the custom, content-owned sidebar resizes or collapses. The tab
/// strip is NOT a toolbar item — toolbar sizing pushed a flexible custom view
/// into the overflow menu — it is plain content, constrained into the chrome
/// row by the window controller. No private view hierarchy is hunted, moved,
/// or constrained anywhere in this file: the ~230 lines that relocated
/// AppKit's NSTabBar died with native tabbing.
final class KeepWindow: NSWindow, NSToolbarDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("keep-main-toolbar")
    private static let toggleSidebarAccessoryIdentifier = NSUserInterfaceItemIdentifier(
        "keep-toggle-sidebar"
    )

    /// The sidebar toggle is chrome, but what it toggles is model state —
    /// the active tab's sidebar. The controller wires this to an intent.
    var onToggleSidebar: (() -> Void)?

    private weak var chromeBackdropView: NSView?
    /// Kept so the toggle can be re-tinted when the terminal's colours move
    /// under it, the same as everything else in this row.
    private weak var sidebarToggleHost: CenteringHost?
    private weak var sidebarBackdropView: NSView?
    private var terminalBackgroundObserver: NSObjectProtocol?

    // The last appearance actually applied, so becomeMain and repeated
    // notifications reapply nothing. Reapplying invalidates the shadow and
    // pokes the WindowServer — visible against a transparent, blurred window.
    private var appliedAppearance: (color: NSColor?, opacity: Double, blur: Int16)?
    /// How many overlays are asking the window to stop being see-through.
    ///
    /// Counted rather than flagged: two of them could be up at once, and the
    /// first one to close must not hand the transparency back while the
    /// second is still relying on it.
    private var opaqueHolds = 0

    /// Stop being see-through while something floats over the window.
    ///
    /// A material blurs what is behind it *within* the window, and where the
    /// window is see-through what is behind it is the desktop — which is how
    /// the picker's card came to be wearing a wallpaper. For as long as the
    /// overlay is up the window is opaque, so the blur has nothing in it but
    /// terminal. The cost is the five per cent of desktop the terminal shows
    /// through itself, gone for the length of a keystroke.
    ///
    /// It does not help Liquid Glass, which was the reason this was written:
    /// `NSGlassEffectView` samples what the window server has *behind* the
    /// window, and an opaque window does not change what is behind it.
    func holdOpaque(_ hold: Bool) {
        let before = opaqueHolds
        opaqueHolds = max(0, opaqueHolds + (hold ? 1 : -1))
        guard (before == 0) != (opaqueHolds == 0) else { return }
        // The appearance is applied only when it changes, and from its own
        // point of view nothing has: the change is in what we are allowed to
        // do with it.
        appliedAppearance = nil
        applyTerminalAppearance()
    }

    deinit {
        if let terminalBackgroundObserver {
            NotificationCenter.default.removeObserver(terminalBackgroundObserver)
        }
    }

    override func becomeKey() {
        super.becomeKey()
        Trace.log("focus", "becomeKey responder=\(Trace.describe(firstResponder))")
        (firstResponder as? TerminalSurfaceView)?.noteFocus()
    }

    override func resignKey() {
        super.resignKey()
        Trace.log("focus", "resignKey")
        // The responder does not change when a window stops being key, so
        // nothing else would tell the terminal it no longer has the keyboard.
        (firstResponder as? TerminalSurfaceView)?.noteFocus()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        Trace.log("responder", "→ \(Trace.describe(responder)) ok=\(ok)")
        return ok
    }

    func installUnifiedToolbar(chromeBackdrop: NSView, sidebarBackdrop: NSView) {
        chromeBackdropView = chromeBackdrop
        sidebarBackdropView = sidebarBackdrop

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        toolbarStyle = .unified
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        self.toolbar = toolbar
        installSidebarToggleAccessory()

        applyTerminalAppearance()
        terminalBackgroundObserver = NotificationCenter.default.addObserver(
            forName: GhosttyApp.backgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTerminalAppearance()
        }
    }

    /// The sidebar's trailing edge moved; the toggle rides it.
    func trackSidebarEdge(_ edge: CGFloat) {
        sidebarToggleHost?.followSidebar(to: edge)
    }

    /// The flat split item deliberately does not have AppKit's `.sidebar`
    /// behavior, so `NSSplitViewController.toggleSidebar` would be a no-op.
    @objc func toggleSidebar(_ sender: Any?) {
        onToggleSidebar?()
    }

    private func applyTerminalAppearance() {
        let ghostty = GhosttyApp.shared
        let next = (
            color: ghostty.terminalBackground,
            opacity: ghostty.terminalBackgroundOpacity,
            blur: ghostty.terminalBackgroundBlur
        )
        if let applied = appliedAppearance,
            applied.color?.isEqual(next.color) ?? (next.color == nil),
            applied.opacity == next.opacity,
            applied.blur == next.blur
        {
            return
        }
        appliedAppearance = next
        sidebarToggleHost?.retint()

        let isTransparent = next.opacity < 1 && opaqueHolds == 0
        if isTransparent {
            // The renderer already draws the configured background colour at
            // `background-opacity`. Keep the host window effectively clear so
            // that alpha reaches the WindowServer instead of being composited
            // over a second opaque copy of the terminal colour.
            isOpaque = false
            backgroundColor = NSColor.white.withAlphaComponent(0.001)

            // The Metal surface starts below the toolbar. Continue the exact
            // same colour and alpha through that clear strip so the titlebar
            // does not reveal an un-tinted desktop behind it.
            if let terminalBackground = next.color {
                let tint = terminalBackground
                    .withAlphaComponent(CGFloat(next.opacity))
                    .cgColor
                chromeBackdropView?.layer?.backgroundColor = tint
                // The sidebar sits a step behind the terminal rather than
                // level with it. The chrome row above the content keeps the
                // content's own colour, because it is the content's row.
                sidebarBackdropView?.layer?.backgroundColor = Self
                    .recessed(terminalBackground)
                    .withAlphaComponent(CGFloat(next.opacity))
                    .cgColor
                chromeBackdropView?.isHidden = false
                sidebarBackdropView?.isHidden = false
            } else {
                chromeBackdropView?.isHidden = true
                sidebarBackdropView?.isHidden = true
            }

            // The same libghostty hook Ghostty's own macOS host uses: reads
            // `background-blur` from the app config and applies WindowServer
            // blur to this NSWindow.
            if let app = ghostty.app {
                ghostty_set_window_background_blur(
                    app,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        } else {
            isOpaque = true
            chromeBackdropView?.isHidden = true
            if let terminalBackground = next.color {
                backgroundColor = terminalBackground.withAlphaComponent(1)
                // Opaque or not, the sidebar is a step behind: the window's
                // own colour paints the content, and the sidebar paints over
                // it with the recessed one.
                sidebarBackdropView?.layer?.backgroundColor = Self
                    .recessed(terminalBackground).cgColor
                sidebarBackdropView?.isHidden = false
            } else {
                sidebarBackdropView?.isHidden = true
            }
        }

        Trace.log(
            "chrome",
            "appearance opacity=\(next.opacity) sidebar=\(sidebarBackdropView?.isHidden == false ? "recessed" : "hidden")")
        invalidateShadow()
    }

    /// A panel's colour: the terminal's, a step further back.
    ///
    /// Taken toward black rather than toward grey, so a terminal with a warm
    /// or cool background keeps its cast instead of washing out — the sidebar
    /// should read as the same room with less light in it, not as a different
    /// surface stuck to the side.
    private static func recessed(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let factor: CGFloat = 0.72
        return NSColor(
            srgbRed: rgb.redComponent * factor,
            green: rgb.greenComponent * factor,
            blue: rgb.blueComponent * factor,
            alpha: rgb.alphaComponent)
    }

    /// The tracking separator follows the split divider all the way to x = 0
    /// when the sidebar collapses, which would push any toolbar item before
    /// it into the overflow menu. A leading titlebar accessory is laid out
    /// independently, so the toggle stays available in both states.
    private func installSidebarToggleAccessory() {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "sidebar.left",
                accessibilityDescription: "Toggle Sidebar"
            ) ?? NSImage(),
            target: self,
            action: #selector(toggleSidebar(_:))
        )
        button.isBordered = false
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Toggle Sidebar (⌘B)"
        // The height of a tab's capsule, so the controls in the chrome are one
        // family. It used to be 28 because that is where the titlebar centred
        // the old bezelled button, and shrinking it moved the control down by
        // the difference — the host below keeps it centred now, so the size is
        // free to be chosen rather than inherited.
        let side: CGFloat = 26
        button.frame = NSRect(x: 0, y: 0, width: side, height: side)

        // The same ground the row's buttons stand on, so the controls
        // in the chrome are made of one thing.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = Self.toggleSidebarAccessoryIdentifier
        accessory.layoutAttribute = .left
        if Glass.isAvailable {
            // Adaptive, not bare glass: Tahoe glass draws its own depth, and
            // over a light titlebar that depth is a coin with a drop shadow.
            // Dark keeps the glass; light gets a flat circle.
            let glass = AdaptiveLozengeView(
                cornerRadius: side / 2,
                lightFill: NSColor.black.withAlphaComponent(0.06))
            // The titlebar stretches an accessory view to its full height,
            // which a bezelled button tolerated and a glass capsule does not:
            // it became a tall rounded slab. So the accessory is a host that
            // stretches, holding a fixed circle it keeps centred.
            // Untinted at rest, like the row's buttons: glass refracts
            // darker than a dark bar, which is the quiet state this wants.
            glass.addSubview(button)
            // The host answers the pointer as well as centring: at rest this
            // is untinted glass and a dim glyph, and under the pointer it
            // lights, which is what the buttons at the far end of the
            // row does. Two controls in one chrome that behave differently
            // read as two kinds of thing, and only one of them as a control.
            let host = CenteringHost(child: glass, control: button, size: side, leading: 4)
            sidebarToggleHost = host
            accessory.view = host
        } else {
            // A bordered button carries its own ground and its own states.
            // Nothing here is glass to light up, so nothing is asked to.
            button.contentTintColor = .secondaryLabelColor
            button.bezelStyle = .circular
            button.isBordered = true
            button.setFrameSize(NSSize(width: 28, height: 28))
            accessory.view = button
        }
        addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - toolbar

    /// No items at all.
    ///
    /// The toolbar earns its place by giving the titlebar its unified height
    /// and letting content run under it; it holds nothing. A tracking
    /// separator used to live here to keep the toolbar's boundary on the
    /// split divider, back when the tab bar was a toolbar item — all it does
    /// now is draw a vertical line down the left of the tab strip, which is a
    /// boundary this chrome does not want.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil
    }
}


/// Keeps one fixed-size child centred while itself being stretched.
///
/// The titlebar sizes an accessory view to the whole of its height, and a
/// control that is a shape — a circle of glass, say — has to stay that shape
/// rather than being stretched into a slab.
private final class CenteringHost: NSView {
    private let child: NSView
    /// The control inside the child, whose glyph brightens under the pointer.
    private weak var control: NSButton?
    private let side: CGFloat
    private let leading: CGFloat
    private var hovered = false

    /// How far the button can be asked to travel.
    ///
    /// The sidebar stops widening at 320, and the button rides its edge, so
    /// the host has to be at least that long to carry it there. Being longer
    /// costs nothing: everything but the button itself is passed straight
    /// through to the row underneath, which is the only reason a strip of
    /// titlebar this wide can belong to a control this small.
    private static let reach: CGFloat = 380
    /// Between the button and the divider it sits against — the same twelve
    /// points a tab's capsule keeps from the buttons at the far end.
    private static let dividerGap: CGFloat = 12

    /// Where the sidebar ends, in the window's coordinates. Zero until told,
    /// and zero whenever the sidebar is collapsed, which is the same thing:
    /// nothing to ride, so the button stays home.
    private var sidebarEdge: CGFloat = 0

    init(child: NSView, control: NSButton? = nil, size: CGFloat, leading: CGFloat) {
        self.child = child
        self.control = control
        self.side = size
        self.leading = leading
        super.init(frame: NSRect(x: 0, y: 0, width: Self.reach, height: size))
        addSubview(child)
        retint()
    }

    /// Follow the sidebar's trailing edge, and stop where the sidebar stops.
    ///
    /// Collapsing does not take the button with it: it rides the edge inward
    /// until the edge passes its home beside the traffic lights, and then it
    /// stays there while the sidebar goes on without it.
    func followSidebar(to edge: CGFloat) {
        guard edge != sidebarEdge else { return }
        sidebarEdge = edge
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.reach, height: NSView.noIntrinsicMetric)
    }

    /// Everything but the button belongs to whatever is underneath.
    ///
    /// This view is as long as the sidebar can be wide, and for most of that
    /// length it is empty titlebar lying over the tab row. A press there is
    /// the row's — a tab to be chosen or carried — and it would never reach
    /// it if this view answered for the whole of itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard childFrame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// Where the child sits. Worked out rather than read back, so that the
    /// pointer is tracked over the same circle the eye sees whether or not a
    /// layout pass has happened yet.
    private var childFrame: NSRect {
        NSRect(
            x: childX,
            y: ((bounds.height - side) / 2).rounded(),
            width: side,
            height: side)
    }

    /// Home is `leading` — hard against the traffic lights, where the button
    /// has always been and where a collapsed sidebar leaves it. Past that it
    /// is wherever the sidebar's edge has got to, measured in this view's own
    /// coordinates so that no one has to know where the titlebar put it.
    private var childX: CGFloat {
        guard window != nil, sidebarEdge > 0 else { return leading }
        let originInWindow = convert(NSPoint.zero, to: nil).x
        return max(leading, sidebarEdge - Self.dividerGap - side - originInWindow)
    }

    /// Untinted glass at rest, which refracts darker than the bar and reads
    /// as a well rather than a lamp; tinted only under the pointer. The same
    /// two states, from the same palette, as the row's buttons.
    func retint() {
        let palette = TabStripView.Palette.current
        if let adaptive = child as? AdaptiveLozengeView {
            adaptive.set(
                cornerRadius: side / 2,
                tint: hovered ? palette.glassTint : nil,
                lightFill: NSColor.black.withAlphaComponent(hovered ? 0.12 : 0.06))
        } else {
            Glass.tint(child, hovered ? palette.glassTint : nil)
        }
        control?.contentTintColor = hovered ? palette.text : palette.dimText
    }

    /// The circle, not the whole accessory. The titlebar stretches this view
    /// to its full height, and lighting the button up for a pointer passing
    /// well above or below it would be answering for something it is not.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: childFrame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self))
        // A control resized or reordered out from under a stationary pointer
        // is never sent `mouseExited`; asking where the mouse is settles it.
        let inside = window.map { window in
            childFrame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        if inside != hovered {
            hovered = inside
            retint()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovered else { return }
        hovered = true
        retint()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered else { return }
        hovered = false
        retint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let place = childFrame
        guard child.frame != place else { return }
        child.frame = place
        // The button moved, so the circle the pointer is watched over moved
        // with it. Nothing else invalidates it: this view's own frame never
        // changed.
        updateTrackingAreas()
        Trace.log("chrome", "toggle at \(Int(convert(place.origin, to: nil).x))")
    }
}
