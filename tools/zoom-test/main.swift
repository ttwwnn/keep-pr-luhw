// The zoom's arithmetic (apps/macos/Sources/Keep/Model/TerminalZoom.swift),
// built with that file and nothing else. Every expected value is written out
// by hand: compared with the expression the code uses, a wrong formula would
// agree with itself.
import Foundation

var failures = 0
func check(_ what: String, _ got: String, _ wanted: String) {
    if got == wanted {
        print("  ok    \(what)")
    } else {
        print("  FAIL  \(what): wanted \(wanted), got \(got)")
        failures += 1
    }
}
func show(_ value: Double?) -> String {
    value.map { String(format: "%g", $0) } ?? "nil"
}
/// Every step from `factor` one way, until there are none.
func walk(from factor: Double, _ direction: Int) -> String {
    var steps: [String] = []
    var at = factor
    while let next = TerminalZoom.step(from: at, direction), steps.count < 30 {
        steps.append(show(next))
        at = next
    }
    return steps.joined(separator: " ")
}

print("steps, Chrome's, from half to three times")
check("larger from 100%", walk(from: 1, 1), "1.1 1.25 1.5 1.75 2 2.5 3")
check("smaller from 100%", walk(from: 1, -1), "0.9 0.8 0.75 0.67 0.5")
check("nothing larger at 300%", show(TerminalZoom.step(from: 3, 1)), "nil")
check("nothing smaller at 50%", show(TerminalZoom.step(from: 0.5, -1)), "nil")

print("between steps: on to the next one, never back to the one passed")
// 15 points of 13: where the palette's old point-at-a-time steps left it.
check("115% larger", show(TerminalZoom.step(from: 15.0 / 13, 1)), "1.25")
check("115% smaller", show(TerminalZoom.step(from: 15.0 / 13, -1)), "1.1")
check("past the top, smaller", show(TerminalZoom.step(from: 40.0 / 13, -1)), "3")
check("past the top, larger", show(TerminalZoom.step(from: 40.0 / 13, 1)), "nil")
check("under the bottom, larger", show(TerminalZoom.step(from: 6.0 / 13, 1)), "0.5")
check("under the bottom, smaller", show(TerminalZoom.step(from: 6.0 / 13, -1)), "nil")

print("a size read back counts as the step it was written for")
// 67% of 14.5 is 9.715, written 9.72: a thousandth over two thirds.
let readBack = TerminalZoom.factor(size: 9.72, base: 14.5)
check("its percentage", TerminalZoom.percent(readBack), "67%")
check("smaller from it skips 67%", show(TerminalZoom.step(from: readBack, -1)), "0.5")
check("larger from it skips 67%", show(TerminalZoom.step(from: readBack, 1)), "0.75")

print("the size written for each step, of 13 points")
/// The value itself, every digit: `%g` would round 11.700000000000001 away.
func exact(_ value: Double?) -> String { value.map { "\($0)" } ?? "nil" }
check("50%", exact(TerminalZoom.fontSize(at: 0.5, base: 13)), "6.5")
check("67%", exact(TerminalZoom.fontSize(at: 0.67, base: 13)), "8.71")
// 13 × 0.9 is 11.700000000000001 in floating point.
check("90% is 11.7, not a hair over", exact(TerminalZoom.fontSize(at: 0.9, base: 13)), "11.7")
check("100% is nothing written", exact(TerminalZoom.fontSize(at: 1, base: 13)), "nil")
check("110%", exact(TerminalZoom.fontSize(at: 1.1, base: 13)), "14.3")
check("125%", exact(TerminalZoom.fontSize(at: 1.25, base: 13)), "16.25")
check("300%", exact(TerminalZoom.fontSize(at: 3, base: 13)), "39.0")
check("110% of 14.5", exact(TerminalZoom.fontSize(at: 1.1, base: 14.5)), "15.95")
check("67% of 14.5, to the hundredth", exact(TerminalZoom.fontSize(at: 0.67, base: 14.5)), "9.72")

print("every step survives the trip through the file")
var trips: [String] = []
for level in TerminalZoom.levels {
    let size = TerminalZoom.fontSize(at: level, base: 13) ?? 13
    let back = TerminalZoom.factor(size: size, base: 13)
    let up = TerminalZoom.step(from: back, 1).map(show) ?? "end"
    trips.append("\(TerminalZoom.percent(back))>\(up)")
}
check("percent and the step after, from the size written",
      trips.joined(separator: " "),
      "50%>0.67 67%>0.75 75%>0.8 80%>0.9 90%>1 100%>1.1 110%>1.25 125%>1.5 150%>1.75 175%>2 200%>2.5 250%>3 300%>end")

print("percentages, rounded as a browser rounds them")
check("100%", TerminalZoom.percent(1), "100%")
check("two thirds", TerminalZoom.percent(2.0 / 3), "67%")
check("15 of 13", TerminalZoom.percent(15.0 / 13), "115%")
check("14.3 of 13", TerminalZoom.percent(TerminalZoom.factor(size: 14.3, base: 13)), "110%")

print("no base, or no size: the text is at its own size")
check("base 0", show(TerminalZoom.factor(size: 13, base: 0)), "1")
check("size 0", show(TerminalZoom.factor(size: 0, base: 13)), "1")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
