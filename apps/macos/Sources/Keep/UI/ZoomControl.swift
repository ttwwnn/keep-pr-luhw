import AppKit

/// The zoom above the sidebar: smaller, how big the text is now, larger.
///
/// Chrome's control, for every terminal in the app (`TerminalZoom`). It sits
/// in the titlebar row beside the sidebar toggle and rides the sidebar's edge
/// with it (`CenteringHost`), and it is made of what the toggle is made of —
/// a well at rest that deepens under the pointer, glyphs that brighten — so
/// the two read as one family. One capsule rather than three more circles:
/// it is one control, and the circle beside it is another.
///
/// The percentage is a button too, back to 100%, as Chrome's zoom bubble has
/// a Reset. Where the sidebar is too narrow for it, it goes and the two
/// buttons stay (`compact`).
@MainActor
final class ZoomControl: NSView {
    /// A tab's capsule tall, and the toggle's circle across.
    static let height: CGFloat = 26
    private static let buttonWidth: CGFloat = 24
    private static let levelWidth: CGFloat = 40

    private let ground = AdaptiveLozengeView(
        cornerRadius: ZoomControl.height / 2,
        lightFill: NSColor.black.withAlphaComponent(0.06))
    private let smaller = NSButton()
    private let level = NSButton()
    private let larger = NSButton()
    /// The part under the pointer, if any.
    private weak var hovered: NSButton?
    private var sizeObserver: NSObjectProtocol?

    /// The two buttons alone, without the percentage between them.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            level.isHidden = compact
            // Gone from under the pointer, the percentage takes its light
            // with it: left lit, the capsule came back lit after the sidebar
            // had been shut and opened with the pointer elsewhere.
            if compact, hovered === level {
                hovered = nil
                retint()
            }
            needsLayout = true
        }
    }

    /// How wide the control is, with the percentage or without it.
    static func width(compact: Bool) -> CGFloat {
        compact ? 2 * buttonWidth : 2 * buttonWidth + levelWidth
    }

    init() {
        super.init(frame: NSRect(
            x: 0, y: 0, width: Self.width(compact: false), height: Self.height))
        addSubview(ground)
        setUp(smaller, symbol: "minus", label: "Zoom Out", id: "keep.zoom.out",
              action: #selector(smallerPressed))
        setUp(level, symbol: nil, label: "Actual Size", id: "keep.zoom.reset",
              action: #selector(levelPressed))
        setUp(larger, symbol: "plus", label: "Zoom In", id: "keep.zoom.in",
              action: #selector(largerPressed))
        // Whoever changed the size — these buttons, the menu, ⌘+, the
        // palette, another window's buttons — this one says so too.
        sizeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyApp.textSizeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
    }

    private func setUp(
        _ button: NSButton, symbol: String?, label: String, id: String, action: Selector
    ) {
        button.isBordered = false
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            button.imagePosition = .imageOnly
        } else {
            button.imagePosition = .noImage
        }
        button.target = self
        button.action = action
        // A click here changes the size of the text, not where it is typed:
        // the keyboard stays with the terminal it was in.
        button.refusesFirstResponder = true
        button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        addSubview(button)
    }

    @objc private func smallerPressed() { GhosttyApp.shared.zoom(by: -1) }
    @objc private func largerPressed() { GhosttyApp.shared.zoom(by: 1) }
    @objc private func levelPressed() { GhosttyApp.shared.resetZoom() }

    /// The percentage, which way there is still somewhere to go, and what
    /// each part says it does.
    private func refresh() {
        let app = GhosttyApp.shared
        let percent = TerminalZoom.percent(app.zoomLevel)
        smaller.isEnabled = app.canZoom(by: -1)
        larger.isEnabled = app.canZoom(by: 1)
        smaller.toolTip = smaller.isEnabled
            ? "Zoom Out (⌘−)" : "Zoomed out as far as it goes (\(percent))"
        larger.toolTip = larger.isEnabled
            ? "Zoom In (⌘+)" : "Zoomed in as far as it goes (\(percent))"
        level.title = percent
        level.toolTip = app.isZoomed
            ? "Zoom \(percent): click for 100% (⌘0)"
            : "Zoom \(percent)"
        retint()
    }

    /// The row's colours, so the control wears whatever the terminal wears.
    /// A well at rest; under the pointer, over a part that would do
    /// something, a deeper one and that part lit.
    func retint() {
        let palette = TabStripView.Palette.current
        let zoomed = GhosttyApp.shared.isZoomed
        let live = hovered.map { $0 === level ? zoomed : $0.isEnabled } ?? false
        ground.set(
            cornerRadius: Self.height / 2,
            tint: live ? palette.glassTint : nil,
            lightFill: NSColor.black.withAlphaComponent(live ? 0.12 : 0.06))
        for button in [smaller, larger] {
            button.contentTintColor = !button.isEnabled
                ? palette.dimText.withAlphaComponent(0.2)
                : button === hovered ? palette.text : palette.dimText
        }
        // Brighter than the buttons while the text is not at its own size:
        // the one thing here worth noticing without looking for it.
        let ink = live && hovered === level ? palette.text
            : zoomed ? palette.hoverText : palette.dimText
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        level.attributedTitle = NSAttributedString(string: level.title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ink,
            .paragraphStyle: centred,
        ])
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let height = bounds.height
        smaller.frame = NSRect(x: 0, y: 0, width: Self.buttonWidth, height: height)
        level.frame = NSRect(
            x: Self.buttonWidth, y: 0, width: compact ? 0 : Self.levelWidth, height: height)
        larger.frame = NSRect(
            x: bounds.width - Self.buttonWidth, y: 0, width: Self.buttonWidth, height: height)
    }

    // MARK: - the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
        // Moved out from under a pointer that held still — the sidebar was
        // dragged, the window resized — a part is never told it was left.
        // Asking where the pointer is settles it.
        point(at: window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) })
    }

    override func mouseEntered(with event: NSEvent) {
        point(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        point(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        point(at: nil)
    }

    override func viewDidHide() {
        super.viewDidHide()
        point(at: nil)
    }

    private func point(at location: NSPoint?) {
        let over = location.flatMap { spot in
            [smaller, level, larger].first { !$0.isHidden && $0.frame.contains(spot) }
        }
        guard over !== hovered else { return }
        hovered = over
        retint()
    }
}
