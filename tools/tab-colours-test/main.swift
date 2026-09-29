// The colours a tab is titled in, checked on the grounds they are drawn on,
// dark and light (UI/Glass.swift, compiled on its own with the two enums it
// colours by tools/tab-colours-test.sh). What is asked:
//   - every state's ink can be read on the terminal's ground and on the
//     sidebar's, in each theme;
//   - no two inks a row can show side by side are the same colour;
//   - the badge of a tab waiting on you is seen against the ground, and its
//     ink read on it at both ends of a breath;
//   - a breath starts and ends on the fill, on one clock for every badge.
import AppKit

var failures = 0, cases = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}
func linear(_ c: CGFloat) -> Double {
    let c = Double(c)
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
func luminance(_ colour: NSColor) -> Double {
    let c = colour.usingColorSpace(.sRGB)!
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
        + 0.0722 * linear(c.blueComponent)
}
/// WCAG's contrast ratio, 1 to 21.
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
/// Distance in OKLab: 0 is the same colour, 0.02 about the least an eye tells apart.
func distance(_ a: NSColor, _ b: NSColor) -> Double {
    func lab(_ colour: NSColor) -> (Double, Double, Double) {
        let c = colour.usingColorSpace(.sRGB)!
        let (r, g, b) = (linear(c.redComponent), linear(c.greenComponent), linear(c.blueComponent))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    let (p, q) = (lab(a), lab(b))
    return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
}
func hex(_ colour: NSColor) -> String {
    let c = colour.usingColorSpace(.sRGB)!
    return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                  Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}

// The grounds: the terminal's, where the strip is drawn, and the sidebar's, a
// step further back (KeepWindow.recessed) — for Keep's dark and light themes.
let grounds: [(dark: Bool, name: String, colour: NSColor)] = [
    (true, "dark terminal", rgb(0x28, 0x2c, 0x34)),
    (true, "dark sidebar", rgb(29, 32, 37)),
    (false, "light terminal", rgb(255, 255, 255)),
    (false, "light sidebar", rgb(244, 244, 244)),
]

for dark in [true, false] {
    let theme = dark ? "dark" : "light"
    var inks: [(String, NSColor)] = ClaudeMode.allCases.map { ("\($0)", $0.color(dark: dark)) }
    for activity in [ClaudeActivity.waitingForWorkflow, .done] {
        inks.append(("\(activity)", activity.color(dark: dark)!))
    }
    for ground in grounds where ground.dark == dark {
        for (name, ink) in inks {
            let ratio = contrast(ink, ground.colour)
            check(ratio >= 3, "\(theme): \(name) \(hex(ink)) reads on the \(ground.name)",
                  String(format: "contrast %.2f", ratio))
        }
        let fill = Attention.fill(dark: dark)
        check(contrast(fill, ground.colour) >= 2.5,
              "\(theme): the badge stands out from the \(ground.name)",
              String(format: "contrast %.2f", contrast(fill, ground.colour)))
    }
    for (i, a) in inks.enumerated() {
        for b in inks[(i + 1)...] {
            let apart = distance(a.1, b.1)
            check(apart >= 0.08, "\(theme): \(a.0) and \(b.0) are told apart",
                  String(format: "%@ %@ OKLab distance %.3f", hex(a.1), hex(b.1), apart))
        }
    }
    for (end, colour) in [("fill", Attention.fill(dark: dark)), ("glow", Attention.glow(dark: dark))] {
        let ratio = contrast(Attention.ink, colour)
        check(ratio >= 4.5, "\(theme): the badge's ink reads at the \(end) of a breath",
              String(format: "contrast %.2f", ratio))
    }
    check(ClaudeActivity.waitingForYou.color(dark: dark) == Attention.ink,
          "\(theme): a turn waiting on you is titled in the badge's ink")
    check(ClaudeActivity.working.color(dark: dark) == nil, "\(theme): a running turn keeps the mode's colour")
}

// The breath.
let period = Attention.period
check(hex(Attention.colour(dark: true, phase: 0)) == hex(Attention.fill(dark: true)), "a breath starts on the fill")
check(hex(Attention.colour(dark: true, phase: 1)) == hex(Attention.glow(dark: true)), "and reaches the glow")
let onBeat = Date(timeIntervalSinceReferenceDate: 1000 * period)
check(Attention.phase(at: onBeat) < 1e-9, "every badge is at the fill on the clock's beat")
check(abs(Attention.phase(at: onBeat.addingTimeInterval(period / 2)) - 1) < 1e-9, "and at the glow halfway")
let since = Date(timeIntervalSinceReferenceDate: 812_345.678)
if let last = Attention.lastBreath(since: since) {
    let after = last.timeIntervalSince(since)
    check(after >= Attention.breathesFor && after < Attention.breathesFor + period,
          "breathing stops within a breath of its minute", "\(after)s")
    check(Attention.phase(at: last) < 1e-6, "and comes to rest on the fill",
          "phase \(Attention.phase(at: last))")
} else {
    check(false, "a tab that started waiting breathes")
}
check(Attention.lastBreath(since: nil) == nil, "a tab not waiting does not breathe")

print("\(cases - failures)/\(cases) ok")
exit(failures == 0 ? 0 : 1)
