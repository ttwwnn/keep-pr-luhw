import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// A borderless window cannot become key — AppKit's default answer, and for
/// a panel whose whole job is taking keystrokes, the wrong one. Without this
/// override `makeKey()` fails silently and every key goes on landing in the
/// app behind, which reads as a terminal you cannot type into.
private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The same hooks KeepWindow has, for the same reason: the surface tells
    /// libghostty it is focused only when asked, and becoming key is the
    /// moment to ask. Without these the cursor stayed a hollow outline — the
    /// terminal's own way of saying "not focused" — while the keys already
    /// worked, which reads as a panel that cannot be interacted with.
    override func becomeKey() {
        super.becomeKey()
        (firstResponder as? TerminalSurfaceView)?.noteFocus()
    }

    override func resignKey() {
        super.resignKey()
        (firstResponder as? TerminalSurfaceView)?.noteFocus()
    }
}

/// The drop-down terminal: ⌃` from anywhere, and a terminal slides in over
/// whatever you were doing; ⌃` again — or clicking away — and it leaves.
///
/// The panel is the ephemeral half. The shell behind it is a Keep tab in a
/// workspace of its own (`quick`), held by the daemon like every other tab —
/// so unlike the usual quake terminal, what is running in it survives the
/// panel, the app, and the login session. Sliding the panel away just stops
/// looking at it.
///
/// An `NSPanel`, borderless and non-activating, on purpose three times over:
/// it can take the keyboard without activating the app (summoning it from
/// another app must not be an app switch); a tiling window manager does not
/// manage panels, so nothing re-tiles when it appears; and it lives outside
/// the window rule's inventory — it is furniture over the desktop, not a
/// window of the session, and `windows.json` never records it.
@MainActor
final class QuickTerminal: NSObject, NSWindowDelegate {
    static let shared = QuickTerminal()

    private var panel: NSPanel?
    private var surface: TerminalSurfaceView?
    private var visible = false
    private var hotKeyRef: EventHotKeyRef?
    private var themeObserver: NSObjectProtocol?

    /// The workspace the panel shows. Its own, so its size vote and its tab
    /// never tangle with anything a window is showing — and still a real
    /// workspace: `keep quick` from any terminal reaches the same shell.
    private static let workspace = Session.quickWorkspace

    // MARK: - the hotkey

    /// ⌃` as a Carbon hotkey: global, no accessibility permission, and the
    /// keystroke is consumed — the app under the pointer never sees it.
    func registerHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                DispatchQueue.main.async { QuickTerminal.shared.toggle() }
                return noErr
            },
            1, &eventType, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4B45_4550), id: 1)  // "KEEP"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave), UInt32(controlKey), id,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func toggle() {
        visible ? hide() : show()
    }

    // MARK: - showing

    private func show() {
        try? Daemon.ensureRunning()
        let panel = ensurePanel()
        guard let screen = screenToUse() else { return }

        let height = (screen.visibleFrame.height * 0.42).rounded()
        let resting = NSRect(
            x: screen.frame.minX,
            y: screen.visibleFrame.maxY - height,
            width: screen.frame.width,
            height: height
        )
        // From just above the top edge, so the motion is a slide, not an
        // appearance. Ordered front before the animation: a panel animating
        // while hidden animates nothing.
        panel.setFrame(resting.offsetBy(dx: 0, dy: height), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        if let surface { panel.makeFirstResponder(surface) }
        visible = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(resting, display: true)
        } completionHandler: { [weak self] in
            guard let self, let surface = self.surface else { return }
            panel.makeFirstResponder(surface)
        }
    }

    private func hide() {
        guard let panel, visible else { return }
        visible = false
        let gone = panel.frame.offsetBy(dx: 0, dy: panel.frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(gone, display: true)
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// Clicking away dismisses — the panel is a visitor, and a visitor that
    /// stays after you have turned to something else is in the way.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - the panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = QuickPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Managed here, not by AppKit: left to itself a panel hides when the
        // app deactivates, which fights the slide and strands `visible`.
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        // Wherever you are: the same panel on every Space, over full-screen
        // apps included.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        // Only the bottom corners: the top edge meets the menu bar.
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.layer?.masksToBounds = true

        // Tab 0 is TAB_ANY: the first live tab of the workspace, created if
        // it has none. The panel never needs to ask the daemon what exists.
        let surface = TerminalSurfaceView(workspace: Self.workspace, tab: 0)
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(surface)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            surface.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            surface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        panel.contentView = content
        self.panel = panel
        self.surface = surface
        applyTheme()
        // The theme moves — a config reload, light to dark — and the panel
        // moves with it, the way the app's own windows do.
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyApp.backgroundDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        return panel
    }

    /// The app's own dress, not a stock material: the panel goes clear, the
    /// surface draws the configured background at its configured opacity, the
    /// margin around it continues the same tint, and the WindowServer blur
    /// comes through the same libghostty hook the app's windows use.
    private func applyTheme() {
        guard let panel, let content = panel.contentView else { return }
        let ghostty = GhosttyApp.shared
        let opacity = ghostty.terminalBackgroundOpacity
        panel.isOpaque = false
        // Not fully clear: a window whose alpha is exactly zero stops
        // getting a shadow, and the shadow is the panel's edge.
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        if let color = ghostty.terminalBackground {
            content.layer?.backgroundColor =
                color.withAlphaComponent(CGFloat(opacity)).cgColor
        }
        if opacity < 1, let app = ghostty.app {
            ghostty_set_window_background_blur(
                app, Unmanaged.passUnretained(panel).toOpaque())
        }
        panel.invalidateShadow()
    }

    /// The screen the pointer is on: the panel is summoned by a keystroke,
    /// and the keystroke's context is wherever the person is working.
    private func screenToUse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
