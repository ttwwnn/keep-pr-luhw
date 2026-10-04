import AppKit
import Foundation
import GhosttyKit

/// The libghostty runtime.
///
/// libghostty owns terminal emulation, font handling and Metal rendering. This
/// app supplies only the platform shell: a window, a view to draw into, and
/// the handful of callbacks the runtime needs to reach macOS.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var failure: String?

    /// Which view each surface renders into, so a runtime action addressed to
    /// a surface can reach its view. Weak: the view's deinit unregisters and
    /// frees the surface, so a stale pointer is never dereferenced.
    private var surfaceViews: [ghostty_surface_t: Weak<TerminalSurfaceView>] = [:]

    func register(surface: ghostty_surface_t, view: TerminalSurfaceView) {
        surfaceViews[surface] = Weak(view)
    }

    func unregister(surface: ghostty_surface_t) {
        surfaceViews[surface] = nil
    }

    func view(for surface: ghostty_surface_t) -> TerminalSurfaceView? {
        surfaceViews[surface]?.value
    }

    /// Posted when the resolved terminal background, opacity, or blur changes.
    static let backgroundDidChange = Notification.Name("keep.terminalBackgroundDidChange")

    /// The colour libghostty fills a surface with, so the strip above the
    /// terminal can match it instead of showing the window's own grey.
    ///
    /// Nil until libghostty says. The config finalized at startup cannot
    /// answer this: a `theme = dark:...,light:...` is still unresolved there
    /// and reading it yields the light colour in a dark window. The resolved
    /// value arrives as an action instead, which is also how a theme change
    /// mid-session reaches us.
    private(set) var terminalBackground: NSColor?
    private(set) var terminalBackgroundOpacity: Double = 1
    private(set) var terminalBackgroundBlur: Int16 = 0

    /// Whether the terminal's ground is dark: the question every colour in
    /// the chrome is an answer to, asked of the colour rather than of the
    /// system. A dark theme in a light macOS is a dark window. Nil until
    /// libghostty has said what the ground is.
    var groundIsDark: Bool? {
        terminalBackground.map(Self.isDark)
    }

    /// Dark or light by how much light a colour gives off — relative
    /// luminance, halfway. The tab strip has always decided this way; now
    /// everything does.
    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }

    /// What this app has been told about the terminal's appearance, over
    /// and above the person's own config. Read once at launch and kept here
    /// rather than fetched: the config file is written from it, and the
    /// palette reader consults it on every keystroke.
    ///
    /// Static because the config is built inside `init`, and anything there
    /// that reached for `shared` would be re-entering the initializer it is
    /// running inside.
    private(set) static var prefs = TerminalPrefs.load()

    /// Adopt a new appearance: write Keep's config, hand it to libghostty,
    /// and forget everything worked out from the old one.
    ///
    /// The reload is the whole mechanism — libghostty resolves the theme for
    /// the scheme in force and reports the settled background back as a
    /// config change, which is what repaints the chrome. Nothing here has to
    /// know what the theme's colours are.
    func adopt(_ newPrefs: TerminalPrefs) {
        guard newPrefs != Self.prefs else { return }
        let sizeChosen = newPrefs.fontSize != Self.prefs.fontSize
        var sameSize = newPrefs
        sameSize.fontSize = Self.prefs.fontSize
        let onlyTheSize = sameSize == Self.prefs
        // Before the reload, which reaches every surface: one off screen
        // keeps the text its program is drawing for until it is shown
        // (`TerminalSurfaceView.holdTextSize`). Not a tab on screen in
        // another window: its program is told of the zoom through that
        // window's surface, and the hidden one's text goes with it.
        if sizeChosen {
            let views = surfaceViews.values.compactMap(\.value)
            let seen = Set(views.filter(\.isShowing).map { "\($0.workspace)/\($0.tab)" })
            for view in views where !seen.contains("\(view.workspace)/\(view.tab)") {
                view.holdTextSize(at: terminalFontSize)
            }
        }
        Self.prefs = newPrefs
        newPrefs.save()
        _paletteCache = [:]
        reloadConfig()
        // The font is read from files rather than asked of libghostty, so it
        // does not arrive with the config change; re-read it here.
        settleFont(announcing: sizeChosen)
        // A step of the zoom changes no colour, and a ground said to have
        // changed is one every tab tells its program about again
        // (`tellScheme`) — a question per Claude Code, per click.
        guard !onlyTheSize else { return }
        NotificationCenter.default.post(name: Self.backgroundDidChange, object: nil)
    }

    /// The font the terminal itself renders with.
    ///
    /// Anywhere the app shows terminal output outside a surface — the picker's
    /// preview, search results — has to use it, or the glyphs a Nerd Font
    /// supplies come out as boxes. Read from the resolved config rather than
    /// named here, so changing the terminal's font changes these too.
    fileprivate(set) var terminalFontFamily: String?
    fileprivate(set) var terminalFontSize: Double = 13
    /// The size the person's own config gives the text, before anything Keep
    /// was told: what the zoom calls 100%.
    fileprivate(set) var ownFontSize: Double = 13

    /// Posted when the terminal's text changes size, for whatever shows how
    /// big it is.
    static let textSizeDidChange = Notification.Name("keep.terminalTextSizeDidChange")

    /// Take the font as the files say it now, and tell whoever shows its
    /// size when that is what moved — or when Keep's choice of it did
    /// (`announcing`) without the text moving: 13 points chosen over an own
    /// 13 is the same text, and still a zoom there is something to undo.
    fileprivate func settleFont(announcing chosen: Bool = false) {
        let font = Self.fontSettings()
        let resized = font.size != terminalFontSize || font.own != ownFontSize
        terminalFontFamily = font.family
        terminalFontSize = font.size
        ownFontSize = font.own
        if resized || chosen {
            NotificationCenter.default.post(name: Self.textSizeDidChange, object: nil)
        }
    }

    fileprivate func adopt(background: NSColor, opacity: Double, blur: Int16) {
        let opacity = min(max(opacity, 0), 1)
        let backgroundChanged = terminalBackground?.isEqual(background) != true
        guard backgroundChanged
            || opacity != terminalBackgroundOpacity
            || blur != terminalBackgroundBlur
        else { return }

        terminalBackground = background
        terminalBackgroundOpacity = opacity
        terminalBackgroundBlur = blur
        if let rgb = background.usingColorSpace(.sRGB) {
            let hex = String(
                format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            Trace.log("chrome", "ground \(hex) \(Self.isDark(background) ? "dark" : "light")")
        }
        NotificationCenter.default.post(name: Self.backgroundDidChange, object: nil)
    }

    /// Read `font-family` from the terminal's own config, and ask libghostty
    /// for `font-size`.
    ///
    /// The face not from `ghostty_config_get`: it answers for typed scalars
    /// like the background colour, but font-family is a repeatable string and
    /// comes back empty. Reading the file the terminal reads is less clever
    /// and actually works. The size is a scalar, asked for as the f32 it is —
    /// see `configuredFontSize`.
    /// Returns rather than assigns: this is called from `init`, and touching
    /// `shared` there re-enters the singleton's own initializer. `own` is the
    /// size before Keep's choice is laid over it.
    fileprivate static func fontSettings() -> (family: String?, size: Double, own: Double) {
        let home = NSHomeDirectory()
        // XDG first, then the macOS location; the later one wins if both set
        // it, matching how the terminal resolves them.
        let paths = [
            (home as NSString).appendingPathComponent(".config/ghostty/config"),
            (home as NSString)
                .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        var family: String?
        var size: Double?
        // The first file that exists wins, whole. The terminal resolves one
        // config location — XDG for preference — rather than merging them,
        // and merging here read a stale macOS-location file over the one the
        // terminal was actually using.
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=")
                else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key {
                case "font-family" where !value.isEmpty: family = value
                case "font-size": size = Double(value)
                default: break
                }
            }
            if family != nil || size != nil { break }
        }
        // The size found above only decides which file the face is read
        // from. The size itself is libghostty's.
        let own = configuredFontSize()
        // And Keep's own choice over theirs, the same way Keep's config file
        // is loaded over theirs. Without this the surfaces would take a face
        // chosen here and everything the app draws terminal text with — the
        // preview, the picker's columns — would go on using the old one.
        if let chosen = prefs.fontFamily, !chosen.isEmpty { family = chosen }
        let chosenSize = prefs.fontSize.flatMap { $0 > 0 ? $0 : nil }
        return (family, chosenSize ?? own, own)
    }

    /// The size the person's own config gives the text, as libghostty itself
    /// resolves it: out of a config built the way `makeConfig` builds one,
    /// less Keep's own file, so every file it reads counts, in its order,
    /// and its default stands where none says.
    ///
    /// Not out of the files: libghostty reads `config` and `config.ghostty`,
    /// in `~/.config/ghostty` and then in Application Support, the last one
    /// winning, and a reading of the first one alone made a 100% that was not
    /// the person's size — on which 110% could be smaller than the text was.
    private static func configuredFontSize() -> Double {
        guard let config = ghostty_config_new() else { return 13 }
        defer { ghostty_config_free(config) }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        var size: Float = 0
        let key = "font-size"
        let found = key.withCString {
            ghostty_config_get(config, &size, $0, UInt(key.utf8.count))
        }
        return found && size > 0 ? Double(size) : 13
    }

    /// The font to show terminal text in outside a surface, at `size` points.
    /// Falls back to the system's monospaced face when the configured family
    /// is not installed — a wrong-looking preview beats an empty one.
    func terminalFont(size: Double? = nil) -> NSFont {
        let points = size ?? terminalFontSize
        let base = terminalFontFamily.flatMap { NSFont(name: $0, size: points) }
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)

        // Terminal output is full of glyphs no ordinary face has — the icons
        // a Nerd Font puts in the private use area, which is why previews
        // came out as boxes. Cascading to one covers them whatever the base
        // face turns out to be, including when the configured family cannot
        // be read at all.
        guard let fallback = Self.nerdFontFamily else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(fontAttributes: [.family: fallback])]
        ])
        return NSFont(descriptor: descriptor, size: points) ?? base
    }

    /// The sixteen colours the terminal was told to use, and the rest of the
    /// two hundred and fifty-six worked out from them.
    ///
    /// Read the same way the font is: out of the config file the terminal
    /// reads, because these are not scalars `ghostty_config_get` will answer
    /// for. A config usually names a theme rather than listing colours, so
    /// the theme is followed to the file that holds them — the ones shipped
    /// inside Ghostty, or the person's own under `~/.config`.
    ///
    /// Cached per appearance: a preview asks for this on every keystroke, and
    /// the answer only changes when the system goes from light to dark.
    func terminalPalette() -> (colors: [NSColor], foreground: NSColor) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let cached = paletteCache[dark] { return cached }
        let resolved = Self.readPalette(dark: dark)
        paletteCache[dark] = resolved
        return resolved
    }

    private var paletteCache: [Bool: (colors: [NSColor], foreground: NSColor)] {
        get { _paletteCache }
        set { _paletteCache = newValue }
    }

    private static func readPalette(dark: Bool) -> (colors: [NSColor], foreground: NSColor) {
        var named: [Int: NSColor] = [:]
        var foreground: NSColor?
        var theme: String?

        func read(_ path: String) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
                    continue
                }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key {
                case "theme": theme = value
                case "foreground": foreground = color(from: value)
                case "palette":
                    // "palette = 4=#89b4fa": the slot, then the colour.
                    guard let split = value.firstIndex(of: "="),
                          let slot = Int(value[..<split].trimmingCharacters(in: .whitespaces)),
                          (0...255).contains(slot),
                          let parsed = color(from: String(value[value.index(after: split)...]))
                    else { break }
                    named[slot] = parsed
                default: break
                }
            }
        }

        let home = NSHomeDirectory()
        for path in [
            (home as NSString).appendingPathComponent(".config/ghostty/config"),
            (home as NSString)
                .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ] where FileManager.default.fileExists(atPath: path) {
            read(path)
            break
        }

        // What Keep has been told beats what the config says, the same way
        // Keep's config file is loaded after theirs. Their own `palette =`
        // lines lose with it: choosing a theme in here means wanting that
        // theme, not that theme with somebody's old overrides showing
        // through.
        let chosen = prefs.theme.flatMap { $0.isEmpty ? nil : $0 }
        if let chosen {
            theme = chosen
            named = [:]
            foreground = nil
        }

        // "dark:Catppuccin Mocha,light:Catppuccin Latte" — one name per
        // appearance, and the one in force is the one to follow.
        if let theme {
            let wanted = theme.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(dark ? "dark:" : "light:") }
                .map { String($0.dropFirst(dark ? 5 : 6)) }
                ?? (theme.contains(":") ? nil : theme)
            if let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
                // The config's own colours win over the theme's, so the theme
                // is read first and anything named directly is put back after.
                // Unless the theme is Keep's own, in which case there is
                // nothing to put back — it was cleared above.
                let direct = named
                let directForeground = foreground
                if let path = ThemeCatalog.path(of: wanted) { read(path) }
                named.merge(direct) { _, own in own }
                if let directForeground { foreground = directForeground }
            }
        }

        var colors = (0..<256).map { standardColor(at: $0) }
        for (slot, color) in named { colors[slot] = color }
        return (colors, foreground ?? colors[7])
    }

    /// The xterm colours: sixteen named ones, a six-by-six-by-six cube, and a
    /// ramp of greys. Only the first sixteen are ever overridden in practice.
    private static func standardColor(at index: Int) -> NSColor {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(
                srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                alpha: 1)
        }
        switch index {
        case 0: return rgb(0, 0, 0)
        case 1: return rgb(205, 49, 49)
        case 2: return rgb(13, 188, 121)
        case 3: return rgb(229, 229, 16)
        case 4: return rgb(36, 114, 200)
        case 5: return rgb(188, 63, 188)
        case 6: return rgb(17, 168, 205)
        case 7: return rgb(229, 229, 229)
        case 8: return rgb(102, 102, 102)
        case 9: return rgb(241, 76, 76)
        case 10: return rgb(35, 209, 139)
        case 11: return rgb(245, 245, 67)
        case 12: return rgb(59, 142, 234)
        case 13: return rgb(214, 112, 214)
        case 14: return rgb(41, 184, 219)
        case 15: return rgb(255, 255, 255)
        case 16...231:
            let n = index - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return rgb(steps[n / 36], steps[(n / 6) % 6], steps[n % 6])
        default:
            let level = 8 + (index - 232) * 10
            return rgb(level, level, level)
        }
    }

    /// `#rrggbb`, or the same without the hash, which both appear in themes.
    private static func color(from text: String) -> NSColor? {
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }

    /// Any installed Nerd Font, found once.
    private var _paletteCache: [Bool: (colors: [NSColor], foreground: NSColor)] = [:]

    /// Any installed Nerd Font, found once.
    private static let nerdFontFamily: String? = NSFontManager.shared
        .availableFontFamilies
        .first { $0.localizedCaseInsensitiveContains("nerd font") }

    /// Read the background out of a config libghostty handed back, which —
    /// unlike one we build ourselves — has `theme = dark:...,light:...`
    /// resolved for the scheme in effect.
    ///
    /// Called straight from the action callback on purpose: the config is
    /// borrowed for the length of that call, and reading it a hop later on
    /// the main queue yields a zeroed struct, which reads as black.
    fileprivate static func background(of config: ghostty_config_t?) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        let key = "background"
        let found = key.withCString {
            ghostty_config_get(config, &color, $0, UInt(key.utf8.count))
        }
        guard found else { return nil }
        return NSColor(color)
    }

    fileprivate static func backgroundOpacity(of config: ghostty_config_t?) -> Double? {
        guard let config else { return nil }
        var opacity: Double = 1
        let key = "background-opacity"
        let found = key.withCString {
            ghostty_config_get(config, &opacity, $0, UInt(key.utf8.count))
        }
        return found ? opacity : nil
    }

    fileprivate static func backgroundBlur(of config: ghostty_config_t?) -> Int16? {
        guard let config else { return nil }
        var blur: Int16 = 0
        let key = "background-blur"
        let found = key.withCString {
            ghostty_config_get(config, &blur, $0, UInt(key.utf8.count))
        }
        return found ? blur : nil
    }

    private init() {
        // A stock theme — `theme = Catppuccin Mocha` — is a file libghostty
        // looks for in its resources directory, found through
        // GHOSTTY_RESOURCES_DIR. Launched from a terminal running inside
        // Ghostty the variable is inherited and everything resolves; launched
        // from the Finder there is no such variable and the theme silently
        // does not apply. Keep bundles no resources of its own, so point at
        // the Ghostty.app that is installed — the same place the theme picker
        // already reads its list from.
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil {
            let ghosttyResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
            if FileManager.default.fileExists(atPath: ghosttyResources) {
                setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 1)
            }
        }

        // libghostty wants the process argv before anything else.
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.unsafeArgv[0].map { [$0] } ?? []
        if ghostty_init(UInt(argv.count), &argv) != 0 {
            failure = "ghostty_init failed"
            return
        }

        guard let config = Self.makeConfig() else {
            failure = "ghostty_config_new failed"
            return
        }
        // These values do not depend on light/dark theme resolution, so make
        // them available before the first window is constructed. The resolved
        // config-change action below will keep all three appearance values in
        // sync after startup and reloads.
        terminalBackgroundOpacity = Self.backgroundOpacity(of: config) ?? 1
        terminalBackgroundBlur = Self.backgroundBlur(of: config) ?? 0
        let font = Self.fontSettings()
        terminalFontFamily = font.family
        terminalFontSize = font.size
        ownFontSize = font.own
        Trace.log("config", "terminal font: \(font.family ?? "system") @\(font.size)pt (own \(font.own)pt)")

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil

        // The runtime asks to be ticked from the main thread.
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                if let app = GhosttyApp.shared.app { ghostty_app_tick(app) }
            }
        }

        // Actions are requests to the platform shell (open a window, set a
        // title, ...). Returning false means "not handled", which is a safe
        // default for everything this app does not implement yet. The ones
        // handled here settle the terminal's background, which the titlebar
        // matches so chrome and content read as one surface.
        runtime.action_cb = { _, target, action in
            switch action.tag {
            case GHOSTTY_ACTION_RENDER:
                // The runtime asking for a frame is the signal the display
                // link only ever approximated: draw this surface, now, and
                // nothing else. Actions can arrive off the main thread; the
                // registry lookup on main guards against a surface freed in
                // between.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface else { return false }
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.runtimeRequestedDraw()
                }
                return true
            case GHOSTTY_ACTION_SET_TITLE:
                // What the program calls itself, the moment it says so.
                // Every other route to this — the daemon's listing — is a
                // poll, and a title that spins deserves better than being
                // sampled.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface,
                    let raw = action.action.set_title.title
                else { return false }
                let title = String(cString: raw)
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.noteTitle(title)
                }
                return true

            case GHOSTTY_ACTION_PWD:
                // Where a new tab or a new pane should start: whatever the
                // shell you are in last said it was in.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface,
                    let raw = action.action.pwd.pwd
                else { return false }
                let pwd = String(cString: raw)
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.noteDirectory(pwd)
                }
                return true

            case GHOSTTY_ACTION_GOTO_SPLIT:
                // The keybinds for this are the person's own, in their
                // ghostty config — `super+alt+h=goto_split:left` and the rest
                // of vim's four. libghostty reads them, resolves the chord and
                // hands the direction over; every one of them used to arrive
                // here, fall through to the default arm, and be traced as an
                // action nobody implemented — which from the keyboard is a
                // shortcut that does nothing at all.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface
                else { return false }
                let towards: TabHostView.Direction?
                switch action.action.goto_split {
                case GHOSTTY_GOTO_SPLIT_LEFT: towards = .left
                case GHOSTTY_GOTO_SPLIT_RIGHT: towards = .right
                case GHOSTTY_GOTO_SPLIT_UP: towards = .up
                case GHOSTTY_GOTO_SPLIT_DOWN: towards = .down
                // Previous and next walk the tree's order rather than the
                // screen's, and nothing in this app asks for them yet.
                default: towards = nil
                }
                guard let towards else { return false }
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.tabHost?.moveFocus(towards)
                }
                return true

            case GHOSTTY_ACTION_RESIZE_SPLIT:
                // The other half of the person's own vim keybinds, alongside
                // goto_split: `super+ctrl+j=resize_split:down,20`. This is the
                // action that showed up in the trace as tag 33, arriving over
                // and over and being answered by nobody.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface
                else { return false }
                let resize = action.action.resize_split
                let way: TabHostView.Direction?
                switch resize.direction {
                case GHOSTTY_RESIZE_SPLIT_LEFT: way = .left
                case GHOSTTY_RESIZE_SPLIT_RIGHT: way = .right
                case GHOSTTY_RESIZE_SPLIT_UP: way = .up
                case GHOSTTY_RESIZE_SPLIT_DOWN: way = .down
                default: way = nil
                }
                guard let way else { return false }
                let amount = CGFloat(resize.amount)
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.tabHost?.resizeSplit(way, by: amount)
                }
                return true

            case GHOSTTY_ACTION_SCROLLBAR:
                // Not handled as a scrollbar — this app draws none — but as
                // the one thing the runtime does say when a terminal's
                // contents move. It is what puts an idle surface back at full
                // rate the instant output arrives.
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                    let surface = target.target.surface else { return false }
                DispatchQueue.main.async {
                    GhosttyApp.shared.view(for: surface)?.noteActivity()
                }
                return false

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                let config = action.action.config_change.config
                guard
                    let color = GhosttyApp.background(of: config),
                    let opacity = GhosttyApp.backgroundOpacity(of: config),
                    let blur = GhosttyApp.backgroundBlur(of: config)
                else { return true }
                // A reload is reported to every surface and then to the app;
                // the font is the app's, and settling it builds a config of
                // its own (`configuredFontSize`), so once a reload, not once
                // a tab.
                let wholeApp = target.tag == GHOSTTY_TARGET_APP
                DispatchQueue.main.async {
                    GhosttyApp.shared.adopt(background: color, opacity: opacity, blur: blur)
                    if wholeApp { GhosttyApp.shared.settleFont() }
                }
                return true
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                DispatchQueue.main.async { GhosttyApp.shared.reloadConfig() }
                return true
            case GHOSTTY_ACTION_COLOR_CHANGE:
                let change = action.action.color_change
                guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return false }
                let color = NSColor(change)
                DispatchQueue.main.async {
                    let app = GhosttyApp.shared
                    app.adopt(
                        background: color,
                        opacity: app.terminalBackgroundOpacity,
                        blur: app.terminalBackgroundBlur
                    )
                }
                return true
            default:
                Trace.log("action", "tag \(action.tag.rawValue) target \(target.tag.rawValue)")
                return false
            }
        }

        // Reading is asked for by a surface and answered by one: the pointer
        // is the view, put there as the surface's userdata when it was made.
        runtime.read_clipboard_cb = { userdata, location, state in
            guard let userdata else { return false }
            // macOS has no selection clipboard, and `supports_selection_
            // clipboard` stays false so nothing should ask for one.
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
            let view = Unmanaged<TerminalSurfaceView>
                .fromOpaque(userdata).takeUnretainedValue()
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            // Not confirmed: let the terminal decide whether this text is the
            // kind that runs itself, and ask below if it is.
            view.completeClipboardRequest(text, state: state, confirmed: false)
            return true
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, state, _ in
            guard let userdata, let string else { return }
            let view = Unmanaged<TerminalSurfaceView>
                .fromOpaque(userdata).takeUnretainedValue()
            let text = String(cString: string)
            DispatchQueue.main.async { view.confirmPaste(text, state: state) }
        }
        runtime.write_clipboard_cb = { _, location, contents, count, _ in
            guard count > 0, let contents else { return }
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
            // Find something to write before touching the pasteboard.
            // Clearing first and then discovering there was nothing to put
            // back destroys whatever the person had copied — which is what
            // copy-on-select did every time a selection came back empty.
            var text: String?
            for i in 0..<Int(count) {
                guard let data = contents[i].data else { continue }
                let candidate = String(cString: data)
                if !candidate.isEmpty { text = candidate; break }
            }
            guard let text else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
        runtime.close_surface_cb = { _, _ in }

        guard let app = ghostty_app_new(&runtime, config) else {
            failure = "ghostty_app_new failed"
            return
        }
        self.app = app

        // A `theme = dark:...,light:...` config is resolved per color scheme,
        // and libghostty assumes light until told otherwise. Setting it on the
        // surface alone is not enough: the choice is made app-wide.
        syncColorScheme()
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.syncColorScheme()
        }
        // And once more, whatever the scheme. The background arrives only
        // with a config change, and the scheme change above is the only thing
        // that makes one at startup — which in a light macOS is not a change
        // at all, since libghostty starts out assuming light. Nothing came,
        // the chrome was never tinted, and the window stood there in the
        // system's white around a dark terminal, with the tab strip still
        // writing in white for the black it had guessed.
        reloadConfig()
    }

    private var appearanceObserver: NSKeyValueObservation?

    /// The keep client a surface runs.
    static var clientBinary: String {
        if let override = ProcessInfo.processInfo.environment["KEEP_BIN"] { return override }
        // Resources, not MacOS: the app executable is "Keep" and macOS
        // filesystems are case-insensitive, so a sibling named "keep" would
        // overwrite the app itself.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/keep").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "keep"
    }

    /// A config built the way this app always builds one.
    ///
    /// Made fresh rather than reused: libghostty asks the platform shell to
    /// reload — it does not reload itself — and handing it a new config is
    /// how the theme gets resolved for the scheme now in effect.
    private static func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // Honour the user's own Ghostty config: same fonts and theme they
        // already tuned, with no separate settings file to maintain.
        ghostty_config_load_default_files(config)

        // Every surface runs the keep client. The per-surface `command` field
        // is ignored by this build of libghostty, so the command is fixed here
        // at app level and each surface names its target through environment
        // variables instead, which are honoured.
        if let overridePath = writeCommandOverride() {
            overridePath.withCString { ghostty_config_load_file(config, $0) }
        }

        ghostty_config_finalize(config)
        return config
    }

    /// Rebuild the config and hand it back, which is what the reload action
    /// asks for — libghostty does not reload itself. The colours are not
    /// read here: this config still has the theme unresolved. libghostty
    /// applies the scheme and reports the settled result as a config change,
    /// which is where they come from.
    fileprivate func reloadConfig() {
        guard let app, let config = Self.makeConfig() else { return }
        ghostty_app_update_config(app, config)
    }

    /// A tiny Ghostty config that points `command` at our client.
    private static func writeCommandOverride() -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("command.conf")
        // `alt+backspace` is spelled out because the encoder does not send it.
        //
        // Measured, not guessed: with the kitty keyboard protocol in force —
        // proven in the same capture, by asking the terminal for its flags
        // and catching the reply — a plain backspace writes 0x7f and an
        // option-backspace writes nothing at all. Every field of the event is
        // by then identical to the one libghostty's own test says must
        // produce `CSI 127;3u`, and unbinding the chord changes nothing, so
        // this is not a binding eating it. Naming the bytes is the one thing
        // that does get them sent, and a word-delete that does nothing is the
        // difference between this being a terminal somebody can work in and
        // not.
        //
        // Keep's native toolbar already provides the outer breathing room.
        // Use a tighter terminal-only inset than the user's standalone
        // Ghostty window so the first prompt sits closer to the chrome.
        //
        // `super+k` is spelled out for a different reason: the terminal binds
        // it to clearing the screen, and clearing the screen is the one thing
        // this terminal must not do on its own. The screen lives in the
        // daemon — a local wipe is undone by the next repaint — and a program
        // drawing a full screen of its own, an editor or Claude Code, keeps
        // its own account of what is on it. Wiped underneath, that account is
        // wrong until something forces a redraw, which reads as the program
        // having broken.
        //
        // So the chord is a keystroke instead: form feed, which is what
        // ctrl-l has always been. A shell clears its screen with it, and a
        // full-screen program redraws — the same gesture, asked of whoever is
        // actually drawing.
        //
        // `shift+tab` is spelled out for the same reason, and measured the
        // same way: outside the kitty keyboard protocol the encoder sends
        // `CSI Z`, the backtab every terminal has sent for decades, and with
        // the protocol in force it sends a plain tab — the shift simply gone.
        // What that costs is any program that cycles one way on tab and the
        // other way on shift-tab: it cycles forwards twice, or does nothing,
        // and from inside there is no way to tell which. `CSI Z` is what the
        // terminal already sends when nobody has turned the protocol on, so
        // naming it here only makes the two agree.
        // Keep's own settings go in the same file, and it is loaded after
        // the person's config, so what has been chosen here wins and what has
        // not been chosen is not mentioned at all.
        let chosen = prefs.configLines
            .map { $0 + "\n" }
            .joined()
        let body = """
            command = \(clientBinary)
            window-padding-y = 0
            \(chosen)
            keybind = alt+backspace=text:\\x1b\\x7f
            keybind = shift+tab=text:\\x1b[Z
            keybind = super+k=text:\\x0c

            """
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            return nil
        }
    }

    /// Follow the system between light and dark.
    func syncColorScheme() {
        guard let app else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - zoom

    /// How big the terminal's text is, as Chrome would say it: 1 is the
    /// person's own size. See `TerminalZoom`.
    var zoomLevel: Double {
        TerminalZoom.factor(size: terminalFontSize, base: ownFontSize)
    }

    /// Whether there is a step to take that way: larger when positive.
    func canZoom(by direction: Int) -> Bool {
        TerminalZoom.step(from: zoomLevel, direction) != nil
    }

    /// Whether the size is Keep's at all, and so anything to go back from.
    var isZoomed: Bool { Self.prefs.fontSize != nil }

    /// One step larger (positive) or smaller (negative), for every tab in
    /// every window at once. Through `adopt`, as any other change to the
    /// terminal's appearance: written down, so the next launch opens at the
    /// same size, and handed to libghostty, which resizes every surface.
    func zoom(by direction: Int) {
        // From the person's size as it is now, not as the last reload left
        // it: their config may have changed since, and a step worked out on
        // the old 100% lands somewhere the next reload calls another name.
        settleFont()
        guard let level = TerminalZoom.step(from: zoomLevel, direction) else { return }
        var next = Self.prefs
        next.fontSize = TerminalZoom.fontSize(at: level, base: ownFontSize)
        adopt(next)
        Trace.log("zoom", "\(TerminalZoom.percent(level)) = \(terminalFontSize)pt")
    }

    /// Back to the person's own size. The face stays whatever was chosen:
    /// this is the zoom's reset, not the palette's.
    func resetZoom() {
        guard isZoomed else { return }
        var next = Self.prefs
        next.fontSize = nil
        adopt(next)
        Trace.log("zoom", "100% = \(terminalFontSize)pt")
    }
}

extension NSColor {
    /// libghostty hands colours over as three bytes, in sRGB.
    fileprivate convenience init(_ color: ghostty_config_color_s) {
        self.init(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }

    fileprivate convenience init(_ change: ghostty_action_color_change_s) {
        self.init(
            srgbRed: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1
        )
    }
}


/// A weak reference that can live in a dictionary value.
private final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
