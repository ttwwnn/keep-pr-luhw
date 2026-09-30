// Where Claude Code's turn stands, read off made-up screens in its real
// shape (ClaudeActivity in Model/Snapshots.swift, extracted and compiled on
// its own by tools/claude-activity-test.sh). Made up, not captured: a real
// screen carries somebody's conversation, and this repository is public.
import Foundation

var failures = 0, cases = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
}

let rule = String(repeating: "─", count: 60)
/// A screen whose turn has ended: its last status line, the prompt box, and
/// the footer under it.
func screen(status: String, footer: String, prompt: String = "❯ ", above: [String] = []) -> String {
    (["⏺ Done: the part that could be done now is finished.", ""] + above
        + [status, "", rule, prompt, rule, "  " + footer]).joined(separator: "\n")
}
func read(_ s: String) -> ClaudeActivity? { ClaudeActivity.read(onScreen: s) }

let mode = "⏵⏵ bypass permissions on"
let tail = "← for agents · ↓ to manage"

// The counts under the box that bring Claude Code back.
for count in ["5 shells, 1 monitor", "1 monitor", "2 monitors", "1 shell", "5 shells",
              "3 background tasks", "1 background task", "1 local agent", "2 local agents",
              "1 background dynamic workflow", "1 MCP task", "2 shells, 3 monitors"] {
    let s = screen(status: "✻ Cooked for 5m 25s · done 12:06 AM · \(count) still running",
                   footer: "\(mode) · \(count) · \(tail)")
    check(read(s) == .waitingForWorkflow, "“· \(count) ·” under the box: waiting, workflow's colour", "\(String(describing: read(s)))")
}
// Counts that are not work the turn is waiting on.
for count in ["1 Artifact comment monitor", "2 Artifact comment monitors", "2 teams", "✻ 1 cloud session",
              "dreaming", "auto-mode scan"] {
    let s = screen(status: "✻ Baked for 23s", footer: "\(mode) · \(count) · \(tail)")
    check(read(s) == .done, "“· \(count) ·”: the turn is over", "\(String(describing: read(s)))")
}
// The last line's "still running" is stale once the count is gone.
let stale = screen(status: "✻ Cooked for 5m 25s · done 12:06 AM · 5 shells, 1 monitor still running",
                   footer: "\(mode) · \(tail)")
check(read(stale) == .done, "“… 1 monitor still running” on the last line alone: over")
// A number in the mode's own words is not a count.
check(read(screen(status: "✻ Baked for 2s", footer: "\(mode) · 2 files changed · \(tail)")) == .done,
      "some other count under the box: over")

// The rules that were there before.
check(read(screen(status: "✶ Roosting… (16m)", footer: "\(mode) · esc to interrupt · \(tail)")) == .working,
      "esc to interrupt: working")
check(read(screen(status: "✻ Waiting for 1 dynamic workflow to finish", footer: "\(mode)\n  ◯ review ▰▰▱ 1/3")) == .waitingForWorkflow,
      "a dynamic workflow listed running: waiting")
check(read(screen(status: "✻ Waiting for 1 dynamic workflow to finish", footer: mode)) == .done,
      "“Waiting for” with nothing listed: over")
check(read(screen(status: "✻ Baked for 23s", footer: mode)) == .done, "a plain ended turn: over")
check(read("Do you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel") == .waitingForYou, "a dialog: waiting for you")

for status in ["Working", "• Working (12s • esc to interrupt)", "Working…", "Workflow"] {
    check(ClaudeActivity.readCodex(onScreen: "Previous message\n\(status)\n\n» \n100% context left") == .waitingForWorkflow,
          "Codex final \(status): workflow's colour")
}
check(ClaudeActivity.readCodex(onScreen: "• Working (12s)\nDone with the task.\n» \n100% context left") == .done,
      "Codex old Working does not colour a later completed message")
check(ClaudeActivity.readCodex(onScreen: "Working tree clean\n» \n100% context left") == .done,
      "a sentence beginning Working is not the running status")
check(ClaudeActivity.readCodex(onScreen: "Working") == nil, "Codex redraw without prompt keeps known state")

print("\(cases - failures)/\(cases) ok")
exit(failures == 0 ? 0 : 1)
