import Foundation
// The app-side test of Worktrees.swift; run by tools/worktrees-test.sh, which
// compiles this with the real file and stubs the two app types it touches.
enum Trace { static func log(_ k: String, _ d: @autoclosure () -> String) {} }
enum Daemon { static var socketPath: String { "/tmp/test-socket" } }

var failures = 0, cases = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    cases += 1; if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
}
let fm = FileManager.default
let dir = ProcessInfo.processInfo.environment["FAKE_DIR"]!
func write(_ name: String, _ object: Any) { try! JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed).write(to: URL(fileURLWithPath: dir + "/" + name)) }
func calls() -> [[String: Any]] {
    ((try? String(contentsOfFile: dir + "/calls.log", encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
func clearCalls() { try? fm.removeItem(atPath: dir + "/calls.log") }

// no helper
setenv("KEEP_WORKTREES_BIN", "/does/not/exist", 1)
let noHelperAtHome = !fm.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/keep-worktrees")
if noHelperAtHome {
    if case .off = Worktrees.list([.init(workspace: "w", tabs: [1])]) { check(true, "no helper: nothing changes") } else { check(false, "no helper: nothing changes") }
} else { print("(skipped: ~/.local/bin/keep-worktrees exists; the 'no helper' case holds only without it)") }
setenv("KEEP_WORKTREES_BIN", dir + "/fake-helper.py", 1)

// listar: the arguments and the text
let wt = dir + "/repo-wt-trash-\(getpid())"
write("listar.json", ["versao": 1,
    "abas": [["alvo": "api:4,7", "pids": [999999]]],
    "lixeira": [["caminho": wt, "ramo": "fix/x", "head": "abc1234", "alteracoes": 3, "commits_so_aqui": 1, "processos": [["pid": 1, "nome": "php"]]],
                ["caminho": NSHomeDirectory() + "/code/wt-loose", "ramo": NSNull(), "head": "f00ba12", "alteracoes": 0, "commits_so_aqui": 0]],
    "mantidas": [["caminho": NSHomeDirectory() + "/code/wt-g", "motivo": "in use by the tab “Report”"]],
    "avisos": ["the conversation of the tab “zsh” was not identified"]])
clearCalls()
let r = Worktrees.list([.init(workspace: "api", tabs: [4, 7]), .init(workspace: "web", tabs: [2])], deadline: 2)
guard case .listing(let l) = r else { print("FAIL  listar was not read"); exit(1) }
let c = calls().first
check((c?["argv"] as? [String]) == ["listar", "--prazo", "2.0", "api:4,7", "web:2"], "listar: arguments", "\(String(describing: c?["argv"]))")
check((c?["socket"] as? String) == "/tmp/test-socket", "listar: hands over the app's socket")
check(l.pids == [999999], "listar: the tabs' pids")
let note = Worktrees.note(for: r)
print("--- note:\n\(note)\n---")
check(note.contains("The 2 worktrees from this tab go to the Trash:"), "note: the heading, plural")
check(note.contains("(branch fix/x; 3 files changed; 1 commit only there; still running inside: php)"), "note: the item's facts")
check(note.contains("• ~/code/wt-loose (no branch, at f00ba12)"), "note: a detached HEAD, and ~")
check(note.contains("Stays where it is:\n• ~/code/wt-g — in use by the tab “Report”"), "note: one kept, with its reason")
check(note.contains("was not identified"), "note: a warning")
check(note.contains("Put Back") && note.contains("no longer known to git"), "note: how to get it back, without promising the worktree")
check(Worktrees.note(for: r, about: "this workspace").contains("The 2 worktrees from this workspace go to the Trash:"), "note: names what is closing")
write("listar.json", ["versao": 1, "abas": [], "lixeira": [], "mantidas": [], "avisos": []])
check(Worktrees.note(for: Worktrees.list([.init(workspace: "w", tabs: [1])])) == "", "note: nothing to say when there is no worktree")
write("listar.json", ["versao": 2])
if case .failed = Worktrees.list([.init(workspace: "w", tabs: [1])]) { check(true, "unknown version: a failure, said") } else { check(false, "unknown version: a failure, said") }
write("listar.json", ["versao": 1]); write("listar-delay.json", 5)
let t0 = Date()
let slow = Worktrees.list([.init(workspace: "w", tabs: [1])], deadline: 1)
if case .failed(let why) = slow { check(Date().timeIntervalSince(t0) < 4 && why.contains("took longer than"), "deadline passed: fails in about 2.5 s", why) } else { check(false, "deadline passed") }
check(Worktrees.note(for: slow).contains("none will be moved"), "deadline passed: the question says nothing moves")
try? fm.removeItem(atPath: dir + "/listar-delay.json")

// moving to the Trash for real
try! fm.createDirectory(atPath: wt, withIntermediateDirectories: true)
try! "x".write(toFile: wt + "/file.txt", atomically: true, encoding: .utf8)
let refused = dir + "/repo-wt-refused-\(getpid())"
try! fm.createDirectory(atPath: refused, withIntermediateDirectories: true)
let waits = dir + "/repo-wt-waits-\(getpid())"
try! fm.createDirectory(atPath: waits, withIntermediateDirectories: true)
write("preparar-" + (refused as NSString).lastPathComponent + ".json", [["versao": 1, "ok": false, "motivo": "locked: test"]])
write("preparar-" + (waits as NSString).lastPathComponent + ".json", [["versao": 1, "ok": false, "motivo": "a process is running", "processos": [["pid": 1]]], ["versao": 1, "ok": true]])
let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1.5"]; try! sleeper.run()
let pid = sleeper.processIdentifier
setenv("FAKE_PID", String(pid), 1)
let item = { (p: String) -> [String: Any] in ["caminho": p] }
write("listar.json", ["versao": 1, "abas": [["alvo": "w:1", "pids": [pid]]], "lixeira": [item(wt), item(refused), item(waits)]])
guard case .listing(let l2) = Worktrees.list([.init(workspace: "w", tabs: [1])]) else { print("FAIL"); exit(1) }
clearCalls()
let t1 = Date()
let problems = Worktrees.trash(l2)
let elapsed = Date().timeIntervalSince(t1)
let argvs = calls().map { ($0["argv"] as? [String]) ?? [] }
let firstPrepare = calls().first { ($0["argv"] as? [String])?.first == "preparar" }
check(elapsed >= 1.3 && firstPrepare?["pid_alive"] as? Bool == false, "waits for the tab's pid to end before moving", "\(elapsed) \(String(describing: firstPrepare))")
check(!fm.fileExists(atPath: wt), "the worktree left its place")
let inTrash = NSHomeDirectory() + "/.Trash/" + (wt as NSString).lastPathComponent
check(fm.fileExists(atPath: inTrash + "/file.txt"), "and is in the Trash with its contents")
check(argvs.contains(["concluir", wt, inTrash]) || argvs.contains { $0.first == "concluir" && $0.count == 3 && $0[1] == wt && $0[2].hasPrefix(NSHomeDirectory() + "/.Trash/") }, "concluir is given where it really went", "\(argvs)")
check(fm.fileExists(atPath: refused), "refused by preparar: it stays")
check(problems.contains { $0.contains("locked: test") }, "the refusal is said as a problem", "\(problems)")
check(!argvs.contains(["concluir", refused]) && !argvs.contains { $0.first == "concluir" && $0[1] == refused }, "refused: no concluir")
check(!fm.fileExists(atPath: waits), "a process running: tried again, and moved")
check(argvs.filter { $0 == ["preparar", waits] }.count == 2, "a process running: prepared twice", "\(argvs)")
check(problems.count == 1, "only one problem", "\(problems)")
print(problems)
// a pid that does not end: nothing moves
let stubborn = Process(); stubborn.executableURL = URL(fileURLWithPath: "/bin/sleep"); stubborn.arguments = ["60"]; try! stubborn.run()
let stays = dir + "/repo-wt-stays-\(getpid())"
try! fm.createDirectory(atPath: stays, withIntermediateDirectories: true)
write("listar.json", ["versao": 1, "abas": [["alvo": "w:1", "pids": [stubborn.processIdentifier]]], "lixeira": [item(stays)]])
guard case .listing(let l3) = Worktrees.list([.init(workspace: "w", tabs: [1])]) else { print("FAIL"); exit(1) }
clearCalls()
let t3 = Date()
let p3 = Worktrees.trash(l3)
check(fm.fileExists(atPath: stays) && p3.first?.contains("still running") == true && !calls().contains { ($0["argv"] as? [String])?.first == "preparar" }, "a conversation still running: nothing moves, and it says why", "\(p3)")
check(Date().timeIntervalSince(t3) >= 19, "a conversation still running: waited the 20 s")
stubborn.terminate(); try? fm.removeItem(atPath: stays)
// a zombie counts as gone
var z: pid_t = 0
let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
posix_spawn(&z, "/usr/bin/true", nil, nil, argv, nil)
Thread.sleep(forTimeInterval: 0.5)
check(kill(z, 0) == 0, "(the child is a zombie: kill(pid, 0) still answers)")
check(Worktrees.waitForExit([z], upTo: 1).isEmpty, "a zombie counts as gone")
var st: Int32 = 0; waitpid(z, &st, 0)
// nasceu_ns goes to preparar
let withBirth = dir + "/repo-wt-id-\(getpid())"
try! fm.createDirectory(atPath: withBirth, withIntermediateDirectories: true)
write("listar.json", ["versao": 1, "abas": [], "lixeira": [["caminho": withBirth, "nasceu_ns": 1790000000123456789]]])
guard case .listing(let l4) = Worktrees.list([.init(workspace: "w", tabs: [1])]) else { print("FAIL"); exit(1) }
clearCalls()
_ = Worktrees.trash(l4)
check(calls().contains { ($0["argv"] as? [String]) == ["preparar", withBirth, "--nasceu", "1790000000123456789"] }, "preparar is told when the listed one was born", "\(calls())")
try? fm.removeItem(atPath: NSHomeDirectory() + "/.Trash/" + (withBirth as NSString).lastPathComponent)
for p in [wt, waits] { try? fm.removeItem(atPath: NSHomeDirectory() + "/.Trash/" + (p as NSString).lastPathComponent) }
try? fm.removeItem(atPath: refused)
print("\(cases - failures)/\(cases) ok"); exit(failures == 0 ? 0 : 1)
