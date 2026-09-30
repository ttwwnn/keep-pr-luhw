import Foundation

var failures = 0, cases = 0
func check(_ ok: Bool, _ label: String) {
    cases += 1
    print("\(ok ? "ok" : "FAIL")  \(label)")
    if !ok { failures += 1 }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let file = root.appendingPathComponent("names.json")
let first = ["name": "Meu nome"]
check(KeepStateFile.write(first, to: file), "initial state written")
check(KeepStateFile.write(["name": "Outro nome"], to: file), "replacement written")
let folder = root.appendingPathComponent("recovery/names.json")
let copies = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
check(copies.count == 1, "previous state archived")
check(try JSONSerialization.jsonObject(with: Data(contentsOf: copies[0])) as? [String: String] == first,
      "archive preserves the user's exact name")
try Data("broken JSON".utf8).write(to: file)
check(KeepStateFile.read(file).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } == first,
      "damaged file recovered from valid saved state")
let damaged = root.appendingPathComponent("damaged.json")
try Data("invalid".utf8).write(to: damaged)
check(!KeepStateFile.write(first, to: damaged), "unrecoverable invalid state is not replaced")
check(try String(contentsOf: damaged) == "invalid", "invalid original retained")
let blocked = root.appendingPathComponent("blocked.json")
check(KeepStateFile.write(first, to: blocked), "seed blocked-backup scenario")
try Data("not a folder".utf8).write(to: root.appendingPathComponent("recovery/blocked.json"))
check(!KeepStateFile.write(["name": "Lost"], to: blocked), "backup failure cancels replacement")
check(try JSONSerialization.jsonObject(with: Data(contentsOf: blocked)) as? [String: String] == first,
      "original survived backup failure")
do {
    try KeepStateFile.validateConnection(socket: "/tmp/foreign.sock", directory: KeepStateFile.productionDirectory)
    check(false, "foreign socket with production state refused")
} catch { check(true, "foreign socket with production state refused") }
do {
    try KeepStateFile.validateConnection(socket: "/tmp/foreign.sock", directory: root)
    check(true, "foreign socket accepts isolated state")
} catch { check(false, "foreign socket accepts isolated state") }

try MainActor.assumeIsolated {
let namesDir = root.appendingPathComponent("names")
let names = NameStore(directory: namesDir)
names.validate(daemonStart: Date(timeIntervalSince1970: 100))
let tab = TabID(workspace: "Work", root: 1)
names.setTab(tab, to: "Nome escolhido")
let namesFile = namesDir.appendingPathComponent("names.json")
let before = try Data(contentsOf: namesFile)
names.validate(daemonStart: Date(timeIntervalSince1970: 200))
check(names.tab(tab) == nil, "new daemon never inherits an unrelated tab's name")
let namesCopies = try fm.contentsOfDirectory(at: namesDir.appendingPathComponent("recovery/names.json"), includingPropertiesForKeys: nil)
check(namesCopies.contains { (try? Data(contentsOf: $0)) == before }, "daemon change retains previous names")

// External restoration between a poll and a user's rename must survive both writes.
var live = try JSONSerialization.jsonObject(with: Data(contentsOf: namesFile)) as! [String: Any]
live["tabs"] = ["Work\u{1f}2": "Restaurada"]
try JSONSerialization.data(withJSONObject: live).write(to: namesFile, options: .atomic)
names.setTab(tab, to: "Renomeada")
check(names.tab(TabID(workspace: "Work", root: 2)) == "Restaurada", "external restoration survives another rename")
check(names.tab(tab) == "Renomeada", "explicit rename wins")
}

print("\(cases - failures)/\(cases) ok")
exit(failures == 0 ? 0 : 1)
