import Foundation

/// Chrome's zoom, for the terminal.
///
/// Every tab in every window gets larger or smaller a step at a time, and
/// the steps are named the way a browser names them: as a share of the size
/// the text normally is. Normally is the person's own — the `font-size` in
/// their Ghostty config, or the terminal's 13 points when it says nothing —
/// so 100% is their terminal exactly as they set it up, and is stored as
/// nothing at all. Any other step is a `font-size` in Keep's own config, the
/// line the palette's "Bigger text" has always written.
///
/// Only the text in the terminals. The sidebar and the tab row stay the size
/// they are, as a browser's own toolbar does when its page is zoomed: they
/// are the frame the work is shown in, and a frame that grew with the work
/// would take the room the zoom was for.
///
/// Arithmetic and nothing else, Foundation only, so a test can be built out
/// of this file alone (tools/zoom-test.sh).
enum TerminalZoom {
    /// Chrome's steps, from half to three times. Past either end a terminal
    /// stops being one: a haze of letters too small to read, or a dozen
    /// columns of letters too big to work in.
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// How far from a step a share may be and still count as that step. A
    /// size is written rounded to the hundredth of a point, so the share read
    /// back is a hair off the step it was written for: 9.72 points is 67% of
    /// 14.5, give or take a thousandth.
    private static let slack = 0.005

    /// The share `size` is of `base`.
    static func factor(size: Double, base: Double) -> Double {
        guard base > 0, size > 0 else { return 1 }
        return size / base
    }

    /// The next step from `factor`: larger when `direction` is positive,
    /// smaller when it is negative, nil when there is none that way.
    ///
    /// A size between two steps — the text can be anywhere a hand-written
    /// `font-size` put it — goes on to the next step in the direction asked,
    /// never back to the one it had already passed.
    static func step(from factor: Double, _ direction: Int) -> Double? {
        direction > 0
            ? levels.first { $0 > factor + slack }
            : levels.last { $0 < factor - slack }
    }

    /// The `font-size` that puts the text at `level` of `base`, or nil for
    /// 100%, which is the person's own size and so nothing of Keep's to
    /// write. Rounded to the hundredth: the file is read by people as well,
    /// and 110% of 13 is 14.3, not 14.300000000000001.
    static func fontSize(at level: Double, base: Double) -> Double? {
        guard abs(level - 1) > 0.0001 else { return nil }
        return (base * level * 100).rounded() / 100
    }

    /// "110%". Whole numbers, as a browser shows them: two thirds is 67%.
    static func percent(_ factor: Double) -> String {
        "\(Int((factor * 100).rounded()))%"
    }
}
