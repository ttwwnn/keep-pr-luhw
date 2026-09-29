import AppKit
import SwiftUI

/// A small glyph that opens a menu: the usage footer's "+".
///
/// AppKit, so that the same control can hang a menu off a glyph in the
/// app's AppKit half as well as in its SwiftUI one; and a view is what can
/// tell the titlebar that a press on it is not the start of a window drag.
///
/// Quiet at rest, lit under the pointer and while its menu is open, and
/// hidden when whoever holds it does not want it — with its menu open it
/// stays, wherever the pointer went meanwhile. The menu is built when it
/// opens, out of what is true then: a cell of the strip shows whichever tab
/// has its place in the row, and the order of the accounts moves while the
/// menu is shut.
@MainActor
final class MenuGlyphButton: NSView {
    /// The menu, asked for at the moment it opens.
    var menuProvider: (() -> NSMenu?)?
    /// Told just before the menu comes up: whatever is being typed nearby is
    /// settled first, as a click elsewhere would.
    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?
    var restingColor: NSColor = .secondaryLabelColor {
        didSet { if restingColor != oldValue { tint() } }
    }
    var litColor: NSColor = .labelColor {
        didSet { if litColor != oldValue { tint() } }
    }
    /// Whether whoever holds it wants it seen.
    var wanted = true {
        didSet { if wanted != oldValue { reveal() } }
    }
    private(set) var isOpen = false
    private var hovered = false
    private let glyph = NSImageView()
    private var symbol: String
    private var pointSize: CGFloat
    private var weight: NSFont.Weight
    /// Where it stands after the last change, so that a state asked for
    /// twice does not fade twice.
    private var showing = true

    init(symbol: String, pointSize: CGFloat = 9, weight: NSFont.Weight = .semibold) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 16))
        wantsLayer = true
        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        glyph.frame = bounds
        glyph.autoresizingMask = [.width, .height]
        // The button is the element; the picture on it is not a second one.
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        setGlyph()
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setSymbol(_ symbol: String, pointSize: CGFloat, weight: NSFont.Weight) {
        guard symbol != self.symbol || pointSize != self.pointSize || weight != self.weight else { return }
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        setGlyph()
    }

    /// Whether it is there to be seen, pointed at and pressed.
    var isShowing: Bool { wanted || isOpen }

    private func setGlyph() {
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        tint()
    }

    private func tint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.contentTintColor = hovered || isOpen ? litColor : restingColor
        CATransaction.commit()
    }

    /// In and out over a sixth of a second, which is the chrome's time for a
    /// control arriving; nothing else about it moves.
    private func reveal() {
        let show = isShowing
        guard show != showing else { return }
        showing = show
        if show { isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.showing else { return }
                self.isHidden = true
            }
        })
    }

    // MARK: - the pointer

    /// A press here opens the menu and is nothing else — not a click on the
    /// tab under it, not the start of a drag of the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isShowing else {
            super.mouseDown(with: event)
            return
        }
        open()
    }

    /// Put the menu up under the glyph, and wait for it to go.
    func open() {
        guard !isOpen, window != nil, let menu = menuProvider?() else { return }
        onWillOpen?()
        isOpen = true
        tint()
        reveal()
        Trace.log("ia", "menu open \(accessibilityIdentifier())")
        // Hanging from the glyph, its edge a little left of it: a pull-down.
        let origin = NSPoint(x: -4, y: isFlipped ? bounds.maxY + 3 : bounds.minY - 3)
        menu.popUp(positioning: nil, at: origin, in: self)
        isOpen = false
        Trace.log("ia", "menu closed \(accessibilityIdentifier())")
        recheckHover()
        tint()
        reveal()
        onDidClose?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
        recheckHover()
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovered else { return }
        hovered = true
        tint()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered else { return }
        hovered = false
        tint()
    }

    /// Where the pointer is, asked rather than remembered: a menu takes the
    /// pointer's events for as long as it is up, and a view moved under a
    /// still pointer is never told it left.
    private func recheckHover() {
        let inside = window.map {
            bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        guard inside != hovered else { return }
        hovered = inside
        tint()
    }

    // MARK: - accessibility

    override func isAccessibilityElement() -> Bool { isShowing }

    /// Opened on the next turn of the run loop, not inside the request: the
    /// menu holds the main thread for as long as it is up, and whoever asked
    /// through the accessibility tree would be kept waiting for an answer
    /// until somebody chose something.
    override func accessibilityPerformPress() -> Bool {
        openSoon()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        openSoon()
        return true
    }

    private func openSoon() {
        DispatchQueue.main.async { [weak self] in self?.open() }
    }
}

/// `MenuGlyphButton` in a SwiftUI view: the footer's "+".
struct MenuGlyph: NSViewRepresentable {
    let symbol: String
    var pointSize: CGFloat = 9
    var weight: NSFont.Weight = .semibold
    let label: String
    let identifier: String
    var help: String?
    var visible = true
    let resting: NSColor
    let lit: NSColor
    let menu: () -> NSMenu?
    var onWillOpen: (() -> Void)?

    func makeNSView(context: Context) -> MenuGlyphButton {
        MenuGlyphButton(symbol: symbol, pointSize: pointSize, weight: weight)
    }

    /// Hands things over and nothing else. This runs inside SwiftUI's update
    /// of the sidebar, and anything done to the keyboard from in here is the
    /// keyboard taken from the terminal (see `SidebarRows`).
    func updateNSView(_ view: MenuGlyphButton, context: Context) {
        view.setSymbol(symbol, pointSize: pointSize, weight: weight)
        if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
        if view.accessibilityIdentifier() != identifier { view.setAccessibilityIdentifier(identifier) }
        if view.toolTip != help { view.toolTip = help }
        view.restingColor = resting
        view.litColor = lit
        view.wanted = visible
        view.menuProvider = menu
        view.onWillOpen = onWillOpen
    }
}

/// The menus the glyphs open.
@MainActor
enum AccountMenu {
    /// The footer's "+": a login to another account of either service.
    static func signIn(_ open: @escaping (AIEngine) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Sign in to another account")
        menu.autoenablesItems = false
        let entries: [(AIEngine, String)] = [
            (.claude, "Sign in to another Claude account…"),
            (.codex, "Sign in to another GPT account…"),
        ]
        for (engine, title) in entries {
            let action = SignIn(engine: engine, open: open)
            let item = NSMenuItem(title: title, action: #selector(SignIn.chosen(_:)), keyEquivalent: "")
            item.representedObject = action
            item.target = action
            menu.addItem(item)
        }
        return menu
    }

    private final class SignIn: NSObject {
        let engine: AIEngine
        let open: (AIEngine) -> Void

        init(engine: AIEngine, open: @escaping (AIEngine) -> Void) {
            self.engine = engine
            self.open = open
        }

        @objc func chosen(_ sender: NSMenuItem) {
            Trace.log("ia", "sign in to \(engine.orderPrefix)")
            let (open, engine) = (self.open, self.engine)
            DispatchQueue.main.async { open(engine) }
        }
    }
}
