import AppKit

/// Liquid Glass, where the system has it.
///
/// `NSGlassEffectView` arrived in macOS 26 and this app deploys to 14, so
/// every use of it is behind a check and every check has a fallback that
/// looked acceptable before glass existed. The fallbacks are not placeholders
/// — they are what the app looked like yesterday.
///
/// Glass belongs on things that float over content: the picker's card, the
/// selected tab's lozenge, a field. It deliberately does not go on the
/// sidebar or the chrome strip, which are tinted with the terminal's own
/// background so that chrome and content read as one surface — refracting
/// there would undo the thing that tinting is for.
enum Glass {
    /// Whether the system can actually draw glass.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Where a panel's material is allowed to look for what to refract.
    enum Backdrop {
        /// The window server's, which is what Liquid Glass samples and is
        /// not ours to redirect. Under an opaque window that is the window;
        /// under a see-through one it is the desktop, wallpaper and all.
        case screen
        /// This window's own content, and nothing past it. The pre-glass
        /// material can be told this; `NSGlassEffectView` cannot, which is
        /// the whole reason the distinction is spelled out here.
        case window
    }

    /// A view that hosts `content` on glass, or on a plain rounded material
    /// where glass does not exist — or where glass would reach past the
    /// window for something to refract and come back with the wallpaper.
    static func panel(
        _ content: NSView, cornerRadius: CGFloat, sampling: Backdrop = .screen
    ) -> NSView {
        if #available(macOS 26.0, *), sampling == .screen {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        // A flat hairline, for a caller that has not drawn its own. One that
        // samples this window has: the material's edge is the same white at
        // every point of the rounding, which reads as a rectangle somebody
        // outlined rather than as a thickness of glass, and the view that
        // wants that fixed is the one that asked to sample the window.
        effect.layer?.borderWidth = sampling == .window ? 0 : 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // A material paints as well as blurs, and what it paints is not a
        // colour anything here chose — `.hudWindow` lays a light grey over
        // the blur whatever is under it, which on a dark theme is a pale
        // card on a black terminal. So the caller gets somewhere to put its
        // own colour: above the blur, below the content, which is the only
        // place a tint can be and still let the blur through.
        let tint = NSView()
        tint.wantsLayer = true
        tint.identifier = Self.tintIdentifier
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// A small glass lozenge with nothing in it — a highlight behind
    /// something else, like the selected tab.
    ///
    /// Returns nil where glass is unavailable, so callers keep painting the
    /// flat fill they already had rather than being handed a stand-in.
    static func lozenge(cornerRadius: CGFloat) -> NSView? {
        guard #available(macOS 26.0, *) else { return nil }
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        return glass
    }

    /// Groups nearby glass so the system can blend them into one another
    /// instead of stacking separate panes of it.
    static func container(spacing: CGFloat, content: NSView) -> NSView {
        guard #available(macOS 26.0, *) else { return content }
        let container = NSGlassEffectContainerView()
        container.spacing = spacing
        container.contentView = content
        return container
    }

    /// Set a glass view's corner radius, if it is one.
    static func setCornerRadius(_ view: NSView, _ radius: CGFloat) {
        guard #available(macOS 26.0, *), let glass = view as? NSGlassEffectView else { return }
        glass.cornerRadius = radius
    }

    /// Tint a glass view, if it is one.
    static func tint(_ view: NSView, _ color: NSColor?) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = color
            return
        }
        // The material path keeps its tint in a view of its own; find it
        // rather than assuming an index, since the content is in there too.
        guard let effect = view as? NSVisualEffectView,
              let tint = effect.subviews.first(where: { $0.identifier == tintIdentifier })
        else { return }
        tint.layer?.backgroundColor = color?.cgColor
    }

    private static let tintIdentifier = NSUserInterfaceItemIdentifier("keep.glass.tint")
}

/// A selection lozenge that is glass on a dark ground and a flat wash on a
/// light one.
///
/// Tahoe's glass draws its own depth — an edge and a shadow — and over a
/// pale surface that depth reads as a pill floating off the list with a drop
/// shadow under it. The dark appearance keeps the glass; the light one gets
/// a plain rounded fill, which is what selection looks like everywhere else
/// on a light macOS.
final class AdaptiveLozengeView: NSView {
    /// Made when the lozenge is first shown, not when it is first built.
    ///
    /// A pane of glass is a window-server resource, and a list makes one of
    /// these per row while showing one at a time: forty rows of a picker,
    /// scrolled, are forty panes of glass created so that the selected row
    /// can wear one. Every list that uses this hides it until the row is
    /// chosen, so being shown is exactly the moment the glass is wanted.
    private var glass: NSView?
    private var radius: CGFloat
    private var lightFill: NSColor
    /// What the tint should be when the glass does arrive, since it can be
    /// set before there is anything to set it on.
    private var tint: NSColor?

    init(cornerRadius: CGFloat, lightFill: NSColor) {
        self.radius = cornerRadius
        self.lightFill = lightFill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isHidden: Bool {
        didSet {
            guard !isHidden else { return }
            makeGlass()
        }
    }

    private func makeGlass() {
        guard glass == nil, let made = Glass.lozenge(cornerRadius: radius) else { return }
        made.frame = bounds
        made.autoresizingMask = [.width, .height]
        Glass.tint(made, tint)
        addSubview(made)
        glass = made
        apply()
    }

    func set(cornerRadius: CGFloat, tint: NSColor?, lightFill: NSColor) {
        radius = cornerRadius
        self.lightFill = lightFill
        self.tint = tint
        if let glass {
            Glass.setCornerRadius(glass, cornerRadius)
            Glass.tint(glass, tint)
        }
        apply()
    }

    override func layout() {
        super.layout()
        glass?.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    /// Again on arrival: `init` runs before the view knows its window, and
    /// `effectiveAppearance` answers for the system then, not for the window
    /// this will live in. Decided too early, the first paint wore the wrong
    /// appearance until something — a manual theme flip, say — forced every
    /// view to re-decide.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = radius
        if dark && glass != nil {
            glass?.isHidden = false
            layer?.backgroundColor = nil
        } else {
            glass?.isHidden = true
            layer?.backgroundColor = lightFill.cgColor
        }
    }
}

// MARK: - Where Claude Code's turn stands

extension ClaudeActivity {
    /// The title's ink, in colours taken from Claude Code's own themes, as
    /// the modes' are. The grey it writes a finished turn's `✻ Baked for
    /// 23s` in, once the turn is over. And while the turn waits on work it
    /// handed off, a plain blue: the calm of something running without you,
    /// and a hue no mode wears — Claude Code's own colour for background
    /// work is a cyan that its plan mode's teal would swallow, and the blue
    /// of its spinner sits a shade from its accept-edits violet. A turn still
    /// running has none: the mode's colour, as before.
    ///
    /// A turn waiting on you is not told by ink. It is the one state in the
    /// row that is somebody's to act on, and it wears a badge — see
    /// `Attention`; the ink here is the one printed on that badge, and means
    /// nothing without it.
    func color(dark: Bool) -> NSColor? {
        switch (self, dark) {
        case (.working, _): return nil
        case (.waitingForWorkflow, true): return srgb(122, 180, 232)
        case (.waitingForWorkflow, false): return srgb(37, 99, 235)
        case (.waitingForYou, _): return Attention.ink
        case (.done, true): return srgb(153, 153, 153)
        case (.done, false): return srgb(102, 102, 102)
        }
    }

    /// Resolved against the appearance it is drawn in; nil where the turn has
    /// no colour of its own.
    var dynamicColor: NSColor? {
        guard self != .working else { return nil }
        return NSColor(name: nil) { appearance in
            color(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ?? .labelColor
        }
    }

    /// Whether the tab is to be marked as waiting on an answer from you.
    var wantsYou: Bool { self == .waitingForYou }
}

/// A turn waiting on an answer — a question, a permission, a plan to
/// approve — drawn to be seen from across the room.
///
/// Every other state in the row is a coloured word, and a coloured word
/// among coloured words does not stand out however loud its colour: the
/// green this used to be sat next to the plan mode's teal and could not be
/// told from it. So this one is a shape rather than a hue — a filled badge,
/// in the vivid orange of Claude Code's own themes (its fast mode's), with
/// dark ink on it the way a warning sign is printed, and a raised hand in
/// front of the name.
///
/// And for its first minute it breathes, while the tab is out of sight,
/// between that orange and a paler one, the ink legible at both ends. Every
/// badge on one clock, so three tabs waiting pulse as one signal rather
/// than as three.
enum Attention {
    /// The badge's ground: Claude Code's vivid orange, its dark theme's on a
    /// dark ground and its light theme's on a light one.
    static func fill(dark: Bool) -> NSColor {
        dark ? srgb(255, 120, 20) : srgb(255, 106, 0)
    }

    /// The far end of a breath: the same orange with light let into it.
    static func glow(dark: Bool) -> NSColor {
        dark ? srgb(255, 178, 112) : srgb(255, 166, 96)
    }

    /// Printed on the badge, at either end of a breath.
    static let ink = srgb(33, 22, 12)

    /// A raised hand: the turn is somebody else's.
    static let symbol = "hand.raised.fill"

    /// One breath, fill to glow and back.
    static let period: TimeInterval = 1.8

    /// Where the breath is at a moment: 0 at the fill, 1 at the glow. Taken
    /// from the clock rather than from when a badge appeared, so that badges
    /// drawn apart — the strip's and the sidebar's, one AppKit and the other
    /// SwiftUI — breathe together.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return (1 - cos(2 * .pi * t)) / 2
    }

    /// The badge's colour at a moment of the breath.
    static func colour(dark: Bool, phase: Double) -> NSColor {
        let from = fill(dark: dark), to = glow(dark: dark)
        let p = CGFloat(max(0, min(1, phase)))
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * p,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * p,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * p,
            alpha: 1)
    }

    /// How long a badge breathes once its tab starts waiting: long enough to
    /// be caught when it happens, and no longer — a tab left waiting for an
    /// afternoon is not to be a light flashing in the corner of the eye all
    /// afternoon. After it the badge holds still, filled and orange, which is
    /// loud enough on its own.
    ///
    /// It breathes under Reduce Motion too. What that setting spares people
    /// is things moving — sliding, zooming, springing — and this moves
    /// nothing: it is a change of colour in place, the one signal here meant
    /// to be caught out of the corner of the eye, and it stops by itself.
    static let breathesFor: TimeInterval = 60

    /// When a badge whose tab started waiting at `since` stops breathing:
    /// the end of the breath that `breathesFor` runs into, so that it comes
    /// to rest on the fill instead of jumping there from halfway.
    static func lastBreath(since: Date?) -> Date? {
        guard let since else { return nil }
        let end = since.addingTimeInterval(breathesFor).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (end / period).rounded(.up) * period)
    }

    /// Breathe a layer's background on the shared clock until `until`, or
    /// hold it still.
    static func pulse(_ layer: CALayer, dark: Bool, until: Date?) {
        let key = "keep.attention.pulse"
        layer.removeAnimation(forKey: key)
        let now = Date()
        guard let until, until > now else { return }
        let breath = CABasicAnimation(keyPath: "backgroundColor")
        breath.fromValue = fill(dark: dark).cgColor
        breath.toValue = glow(dark: dark).cgColor
        breath.duration = period / 2
        breath.autoreverses = true
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Started as far into a breath as the clock already is, so this badge
        // joins the others where they are instead of starting its own; and
        // as many whole breaths from there as reach `until`, which is where
        // one of them ends.
        let into = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        breath.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - into
        breath.repeatCount = Float(((until.timeIntervalSince(now) + into) / period).rounded())
        breath.fillMode = .backwards
        layer.add(breath, forKey: key)
    }
}

/// Colours given as the bytes Claude Code's themes spell them in.
private func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

// MARK: - Claude Code's mode colours

extension ClaudeMode {
    /// The colour Claude Code gives this mode under its prompt, taken from
    /// its own themes: the dark one on a dark ground, the light one on a light
    /// ground. A tab named in it reads as the same thing the footer says.
    func color(dark: Bool) -> NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch (self, dark) {
        case (.plan, true): rgb = (72, 150, 140)
        case (.plan, false): rgb = (0, 102, 102)
        case (.acceptEdits, true): rgb = (175, 135, 255)
        case (.acceptEdits, false): rgb = (135, 0, 255)
        case (.bypass, true): rgb = (255, 107, 128)
        case (.bypass, false): rgb = (171, 43, 63)
        case (.auto, true): rgb = (255, 193, 7)
        case (.auto, false): rgb = (150, 108, 30)
        }
        return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    /// The same, resolved against whatever appearance it is drawn in — for
    /// views that follow the window's appearance rather than the terminal's
    /// background.
    var dynamicColor: NSColor {
        NSColor(name: nil) { appearance in
            color(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }
}
