import AppKit
import Foundation

/// What this app has been told about the terminal's appearance.
///
/// Written into a config file of Keep's own, loaded *after* the person's
/// Ghostty config, so it wins where it says anything and stands aside where
/// it does not. Their own config is never edited: it is read by the Ghostty
/// they also run, and a terminal that rewrites the file behind another
/// program's back is a terminal you cannot keep two of.
///
/// Empty by default, which is the whole design — a fresh Keep looks exactly
/// like their Ghostty, and only what they change here stops matching it.
struct TerminalPrefs: Codable, Equatable {
    /// A Ghostty theme name, as it appears in the themes directory.
    var theme: String?
    var fontFamily: String?
    var fontSize: Double?
    /// "light" or "dark" to hold Keep to one, whatever the system is doing;
    /// nil to follow it. Which half of a `dark:…,light:…` theme the
    /// terminal wears, and so what the chrome around it wears too.
    ///
    /// Not a config line: it is not the terminal's setting but the app's,
    /// and it reaches libghostty the way the system's own does — as the
    /// scheme the app is in.
    var appearance: String?

    /// The appearance these ask the app to be in: nil for the system's.
    var nsAppearance: NSAppearance? {
        switch appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    static let none = TerminalPrefs()

    private static var file: URL {
        stateDirectory().appendingPathComponent("terminal.json")
    }

    static func load() -> TerminalPrefs {
        guard let data = try? Data(contentsOf: file),
              let prefs = try? JSONDecoder().decode(TerminalPrefs.self, from: data)
        else { return .none }
        return prefs
    }

    func save() {
        let file = Self.file
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// The lines that go into Keep's own config file. Nothing for what has
    /// not been chosen: an unset field must leave the person's own setting
    /// alone, and a `theme =` with nothing after it is not "unset", it is a
    /// theme called nothing.
    var configLines: [String] {
        var lines: [String] = []
        if let theme, !theme.isEmpty { lines.append("theme = \(theme)") }
        if let fontFamily, !fontFamily.isEmpty {
            // `font-family` is a *list*, not a scalar: naming one appends a
            // fallback rather than replacing the primary, so ours landed
            // behind theirs and the terminal went on using their face. An
            // empty value resets the list, which is the documented way to
            // replace instead of add.
            lines.append("font-family = ")
            lines.append("font-family = \(fontFamily)")
        }
        if let fontSize, fontSize > 0 {
            lines.append("font-size = \(String(format: "%g", fontSize))")
        }
        return lines
    }
}

/// The themes on this machine.
///
/// Ghostty ships four hundred and sixty-odd of them and this app already
/// knows how to read one — following `theme = …` to the file that holds the
/// colours is how the picker's preview has always been coloured. So the
/// catalogue is not a list Keep maintains; it is a directory listing.
///
/// Which also decides how it fails: no Ghostty installed and no themes of
/// your own means no list, and the command that opens it says so rather than
/// offering an empty one.
enum ThemeCatalog {
    /// Where themes live, nearest first: yours beat the ones that shipped.
    static var directories: [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent(".config/ghostty/themes"),
            (home as NSString).appendingPathComponent(
                "Library/Application Support/com.mitchellh.ghostty/themes"),
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
    }

    /// Every theme name, once each, in the order a list of names should be
    /// read in. Cached: this is a directory of four hundred entries and the
    /// palette asks for it on every keystroke.
    static var names: [String] {
        if let cached = cachedNames { return cached }
        var seen = Set<String>()
        var found: [String] = []
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in entries where !name.hasPrefix(".") {
                guard seen.insert(name).inserted else { continue }
                found.append(name)
            }
        }
        // Case-insensitive, or `Zenburn` sorts above `ayu` and the list looks
        // like two lists.
        found.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cachedNames = found
        return found
    }

    private static var cachedNames: [String]?

    static func path(of theme: String) -> String? {
        directories
            .map { ($0 as NSString).appendingPathComponent(theme) }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A theme's own colours, for showing it before it is chosen.
    ///
    /// The sixteen named slots, the background and the foreground — which is
    /// all a swatch or a sample needs, and all most theme files set. Cached
    /// per name because the list draws these as it scrolls.
    struct Colors: Equatable {
        var background: NSColor
        var foreground: NSColor
        /// Slots 0–15, the ones a theme actually names.
        var ansi: [NSColor]
    }

    static func colors(of theme: String) -> Colors? {
        if let cached = cache[theme] { return cached }
        guard let path = path(of: theme),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var ansi = [NSColor](repeating: .clear, count: 16)
        var filled = Set<Int>()
        var background: NSColor?
        var foreground: NSColor?
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
            case "background": background = color(from: value)
            case "foreground": foreground = color(from: value)
            case "palette":
                guard let split = value.firstIndex(of: "="),
                      let slot = Int(value[..<split].trimmingCharacters(in: .whitespaces)),
                      (0...15).contains(slot),
                      let parsed = color(from: String(value[value.index(after: split)...]))
                else { break }
                ansi[slot] = parsed
                filled.insert(slot)
            default: break
            }
        }
        guard let background, let foreground, filled.count >= 8 else { return nil }
        // A theme that named only half its slots leaves the rest as whatever
        // a terminal would have used anyway, rather than as clear.
        for slot in 0..<16 where !filled.contains(slot) {
            ansi[slot] = fallback(at: slot)
        }
        let resolved = Colors(background: background, foreground: foreground, ansi: ansi)
        cache[theme] = resolved
        return resolved
    }

    private static var cache: [String: Colors] = [:]

    private static func color(from text: String) -> NSColor? {
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }

    private static func fallback(at slot: Int) -> NSColor {
        let xterm: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
        ]
        let (r, g, b) = xterm[min(max(slot, 0), 15)]
        return NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
            alpha: 1)
    }
}

/// The monospaced faces installed here.
///
/// Filtered by `isFixedPitch` rather than by name: a terminal set in a
/// proportional face is not a terminal, and the list is long enough without
/// every display face on the machine in it.
enum FontCatalog {
    static var monospaced: [String] {
        if let cached = cache { return cached }
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        let sorted = families.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        cache = sorted
        return sorted
    }

    private static var cache: [String]?
}
