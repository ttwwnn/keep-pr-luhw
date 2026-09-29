import Foundation
// The model test of AIUsage.swift (the usage footer's facts and the order of
// priority) and of the `keep-ia` half of Daemon/ExternalHelper.swift, run by
// tools/usage-test.sh. Foundation only: no app, no network, no real logins,
// no real helper.

// The two app types ExternalHelper.swift reaches for, stubbed.
enum Trace { static func log(_ kind: String, _ detail: @autoclosure () -> String) {} }
enum Daemon { static var socketPath: String { "/tmp/test-socket-usage" } }

var failures = 0
var cases = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
}

// Run under a made-up HOME (tools/usage-test.sh), where the installed helper
// is a canary: nothing here may reach the real ~/.local/bin/keep-ia and the
// real accounts it acts on, not even with the code under test broken on
// purpose. Refused outright otherwise.
let testEnvironment = ProcessInfo.processInfo.environment
guard let testHome = testEnvironment["HOME"], testHome != NSHomeDirectory(),
      AIHelper.installedPath(environment: testEnvironment) == testHome + "/.local/bin/keep-ia"
else {
    print("FAIL  refusing to run: HOME must be a made-up home, and the installed helper looked for in it"
          + " (\(AIHelper.installedPath(environment: testEnvironment)))")
    exit(2)
}

// --- answers in the services' real shape, with no secrets in them
let claudeReal = """
{"five_hour":{"utilization":17.0,"resets_at":"2026-09-27T04:50:00.275240+00:00","limit_dollars":null},
 "seven_day":{"utilization":88.0,"resets_at":"2026-09-28T10:00:00.275265+00:00"},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "nimbus_quill":{"utilization":0.0,"resets_at":null},
 "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
 "limits":[
  {"kind":"session","group":"session","percent":17,"severity":"normal","resets_at":"2026-09-27T04:50:00.275240+00:00","scope":null},
  {"kind":"weekly_all","group":"weekly","percent":88,"severity":"warning","resets_at":"2026-09-28T10:00:00.275265+00:00","scope":null},
  {"kind":"weekly_scoped","group":"weekly","percent":32,"severity":"normal","resets_at":"2026-09-28T10:00:00.275265+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
 ]}
""".data(using: .utf8)!

let r = UsageParse.claude(claudeReal)
check(r?.windows.map(\.label) == ["5h", "7d", "Fable"], "claude: windows 5h, 7d and Fable", "\(String(describing: r?.windows.map(\.label)))")
check(r?.windows.map(\.percent) == [17, 88, 32], "claude: percentages", "\(String(describing: r?.windows.map(\.percent)))")
check(r?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1790484600), "claude: a reset with six decimals and +00:00", "\(String(describing: r?.windows.first?.resetsAt?.timeIntervalSince1970))")
check(r?.limitReached == false, "claude: not at the limit")
check(r?.windows.contains { $0.label == "Extra" } == false, "claude: extra credits switched off are not shown")

let claudeOld = """
{"five_hour":{"utilization":1.0,"resets_at":"2026-09-27T04:50:00Z"},"seven_day":{"utilization":100,"resets_at":null},
 "seven_day_opus":{"utilization":40,"resets_at":"2026-09-28T10:00:00Z"},"seven_day_sonnet":null,
 "extra_usage":{"is_enabled":true,"utilization":12.5,"used_credits":1,"monthly_limit":8}}
""".data(using: .utf8)!
let a = UsageParse.claude(claudeOld)
check(a?.windows.map(\.label) == ["5h", "7d", "Opus", "Extra"], "claude without limits: Opus and Extra", "\(String(describing: a?.windows.map(\.label)))")
check(a?.windows.first?.percent == 1.0, "claude: utilization 1.0 is 1%, not 100%")
check(a?.limitReached == true, "claude: 100% is the limit")
let zero = UsageParse.claude(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0.0},"extra_usage":{"is_enabled":true,"utilization":true}}"#.data(using: .utf8)!)
check(zero?.windows.map(\.label) == ["5h", "7d"] && zero?.windows.map(\.percent) == [0, 0], "0% is shown; a boolean is not a figure", "\(String(describing: zero?.windows))")
check(UsageParse.claude("{}".data(using: .utf8)!) == nil, "claude: an answer with no windows is nil")
check(UsageParse.claude("not json".data(using: .utf8)!) == nil, "claude: garbage is nil")

let codexReal = """
{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
 "primary_window":{"used_percent":2,"limit_window_seconds":604800,"reset_after_seconds":578124,"reset_at":1791047982},
 "secondary_window":null},"additional_rate_limits":null}
""".data(using: .utf8)!
let c = UsageParse.codex(codexReal)
check(c?.windows.map(\.label) == ["7d"], "codex: one weekly window", "\(String(describing: c?.windows.map(\.label)))")
check(c?.windows.first?.percent == 2 && c?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1791047982), "codex: 2% and a reset in epoch seconds")
let codexTwo = """
{"rate_limit":{"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_at":1790000000},
 "secondary_window":{"used_percent":55.5,"limit_window_seconds":604800,"reset_at":1790500000}},
 "additional_rate_limits":[{"limit_name":"codex-mini","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":86400,"reset_at":1790100000}}}]}
""".data(using: .utf8)!
let c2 = UsageParse.codex(codexTwo)
check(c2?.windows.map(\.label) == ["5h", "7d", "codex-mini 1d"], "codex: 5h, 7d and an additional limit", "\(String(describing: c2?.windows.map(\.label)))")
check(c2?.limitReached == true, "codex: limit_reached")

let perModel = UsageParse.claude(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":50},"limits":[{"kind":"weekly_scoped","percent":100,"scope":{"model":null,"surface":{"display_name":"Claude Code"}}}],"extra_usage":{"is_enabled":true,"utilization":100}}"#.data(using: .utf8)!)
check(perModel?.windows.map(\.label) == ["5h", "7d", "Claude Code", "Extra"], "a window scoped to a surface is named by it", "\(String(describing: perModel?.windows.map(\.label)))")
check(perModel?.limitReached == false, "a per-model window or extra credits at 100% do not block the account")
let additional = UsageParse.codex(#"{"rate_limit":{"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"GPT-X","rate_limit":{"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}]}"#.data(using: .utf8)!)
check(additional?.limitReached == false && additional?.windows.last?.label == "GPT-X 5h", "an additional Codex limit at 100% does not block the account", "\(String(describing: additional))")

// --- discovery in a made-up home
let fm = FileManager.default
let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keep-usage-\(getpid())")
try? fm.removeItem(at: home)
let vault = home.appendingPathComponent(".claude/contas")
try! fm.createDirectory(at: vault, withIntermediateDirectories: true)
func slot(_ name: String, _ body: [String: Any]) {
    try! JSONSerialization.data(withJSONObject: body).write(to: vault.appendingPathComponent("\(name).json"))
}
let now = Date()
func oauth(_ token: String, expires: Date, tier: String = "default_claude_max_20x", subscription: String = "max") -> [String: Any] {
    ["claudeAiOauth": ["accessToken": token, "refreshToken": "r", "expiresAt": expires.timeIntervalSince1970 * 1000,
                       "subscriptionType": subscription, "rateLimitTier": tier]]
}
slot("main", ["apelido": "main", "email": "a@example.com", "accountUuid": "U1", "credenciais": oauth("t-old", expires: now.addingTimeInterval(3600))])
slot("work", ["apelido": "work", "email": "a@example.com", "accountUuid": "U1", "credenciais": oauth("t-new", expires: now.addingTimeInterval(7200))])
slot("spare", ["apelido": "spare", "email": "b@example.com", "accountUuid": "U2", "refreshMorto": "abc123", "credenciais": oauth("t2", expires: now.addingTimeInterval(60), tier: "default_claude_pro", subscription: "pro")])
try! "work\n".write(to: vault.appendingPathComponent(".ativa"), atomically: true, encoding: .utf8)
try! "spare".write(to: vault.appendingPathComponent(".preferida"), atomically: true, encoding: .utf8)
try! "{}".write(to: vault.appendingPathComponent(".hidden.json"), atomically: true, encoding: .utf8)

func b64url(_ o: [String: Any]) -> String {
    try! JSONSerialization.data(withJSONObject: o).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let exp = now.addingTimeInterval(86400).timeIntervalSince1970.rounded()
let jwt = "h." + b64url(["exp": exp, "https://api.openai.com/profile": ["email": "c@example.com"],
                           "https://api.openai.com/auth": ["chatgpt_plan_type": "pro", "chatgpt_account_id": "ACC"]]) + ".s"
try! fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": jwt, "account_id": "ACC", "refresh_token": "r"]])
    .write(to: home.appendingPathComponent(".codex/auth.json"))

let accounts = AIAccounts.discover(home: home)
check(accounts.count == 3, "discovery: 2 Claude (one duplicate merged) + 1 Codex", "\(accounts.map(\.alias))")
check(accounts.first?.alias == "spare" && accounts.first?.isPreferred == true, "order: the preferred one first", "\(accounts.map(\.alias))")
let u1 = accounts.first { $0.key == "U1" }
check(u1?.alias == "work" && u1?.isActive == true, "duplicate: shown under the active slot's name", "\(String(describing: u1?.alias))")
check(u1?.aliases.sorted() == ["main", "work"], "duplicate: both slot names kept")
check(u1?.token == "t-new", "duplicate: the fresher token is kept")
check(u1?.plan == "Max 20x", "plan Max 20x")
let spare = accounts.first { $0.key == "U2" }
check(spare?.warning != nil && spare?.plan == "Pro", "a refused refresh becomes a warning; an unknown tier falls back on the subscription", "\(String(describing: spare?.plan))")
let gpt = accounts.first { $0.engine == .codex }
check(gpt?.alias == "main" && gpt?.email == "c@example.com" && gpt?.plan == "Pro" && gpt?.accountHeader == "ACC", "codex: its only account is the main one, with address, plan and workspace", "\(String(describing: gpt))")
check(gpt?.expiresAt == Date(timeIntervalSince1970: exp), "codex: the JWT's expiry")
check(AIAccounts.discover(home: URL(fileURLWithPath: "/does/not/exist")).isEmpty, "no vault and no codex: no accounts")

// --- requests: a stand-in address only on 127.0.0.1
let v = (claude: "2.1.283", codex: "0.157.0")
let rq = UsageEndpoint.request(for: u1!, environment: [:], clientVersions: v)
check(rq?.url == UsageEndpoint.claude, "claude: the real URL")
check(rq?.value(forHTTPHeaderField: "Authorization") == "Bearer t-new", "claude: Bearer")
check(rq?.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.283 (external, cli)", "claude: a CLI's User-Agent")
check(rq?.httpMethod == "GET", "claude: GET")
let local = UsageEndpoint.request(for: u1!, environment: ["KEEP_AI_USAGE_CLAUDE_URL": "http://127.0.0.1:9999/u"], clientVersions: v)
check(local?.url?.absoluteString == "http://127.0.0.1:9999/u", "a stand-in on this machine is taken")
for elsewhere in ["https://evil.example/u", "http://127.0.0.1.evil.example/u", "http://localhost:9999/u", "https://127.0.0.1:9999/u"] {
    let x = UsageEndpoint.request(for: u1!, environment: ["KEEP_AI_USAGE_CLAUDE_URL": elsewhere], clientVersions: v)
    check(x?.url == UsageEndpoint.claude, "stand-in refused: \(elsewhere)", "\(String(describing: x?.url))")
}
let rqc = UsageEndpoint.request(for: gpt!, environment: [:], clientVersions: v)
check(rqc?.url == UsageEndpoint.codex && rqc?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "ACC", "codex: URL and ChatGPT-Account-Id")
let noToken = AIAccount(engine: .claude, key: "k", alias: "a", aliases: ["a"], email: nil, plan: nil, isActive: false,
                        isPreferred: false, token: nil, accountHeader: nil, expiresAt: nil, warning: nil)
check(UsageEndpoint.request(for: noToken, environment: [:], clientVersions: v) == nil, "no token: no request")
check(!u1!.summary.id.isEmpty && !"\(u1!.summary)".contains("t-new"), "the published summary carries no token")

// --- installed versions
let bin = home.appendingPathComponent(".local/bin")
try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
let versions = home.appendingPathComponent(".local/share/claude/versions")
try! fm.createDirectory(at: versions, withIntermediateDirectories: true)
fm.createFile(atPath: versions.appendingPathComponent("9.8.7").path, contents: Data())
try! fm.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: versions.appendingPathComponent("9.8.7"))
let rel = home.appendingPathComponent(".codex/packages/standalone/releases/1.2.3-aarch64-apple-darwin/bin")
try! fm.createDirectory(at: rel, withIntermediateDirectories: true)
fm.createFile(atPath: rel.appendingPathComponent("codex").path, contents: Data())
let cur = home.appendingPathComponent(".codex/packages/standalone/current")
try! fm.createSymbolicLink(at: cur, withDestinationURL: home.appendingPathComponent(".codex/packages/standalone/releases/1.2.3-aarch64-apple-darwin"))
try! fm.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: cur.appendingPathComponent("bin/codex"))
let iv = UsageEndpoint.installedVersions(home: home)
check(iv.claude == "9.8.7" && iv.codex == "1.2.3", "versions read off the links", "\(iv)")
let iv0 = UsageEndpoint.installedVersions(home: URL(fileURLWithPath: "/does/not/exist"))
check(iv0.claude == "2.1.283" && iv0.codex == "0.157.0", "versions: the defaults without the tools")

// --- text
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
check(UsageText.until(t0.addingTimeInterval(41 * 60), now: t0) == "41min", "41min to go")
check(UsageText.until(t0.addingTimeInterval(4 * 3600 + 10 * 60), now: t0) == "4h10", "4h10 to go")
check(UsageText.until(t0.addingTimeInterval(3 * 3600), now: t0) == "3h", "3h to go")
check(UsageText.until(t0.addingTimeInterval(37 * 3600 + 5), now: t0) == "1d13h", "1d13h to go", "\(String(describing: UsageText.until(t0.addingTimeInterval(37 * 3600 + 5), now: t0)))")
check(UsageText.until(t0.addingTimeInterval(-5), now: t0) == "now", "a reset in the past: now")
check(UsageText.until(nil, now: t0) == nil, "no reset: nothing")
check(UsageText.percent(16.6) == "17%" && UsageText.percent(-3) == "0%", "a percentage rounded and never negative")
check(UsageText.level(74.9) == .normal && UsageText.level(75) == .attention && UsageText.level(89.9) == .attention && UsageText.level(90) == .critical, "thresholds 75/90")
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
check(UsageText.moment(cal.date(byAdding: .hour, value: 3, to: noon)!, now: noon, calendar: cal) == "today at 15:00", "moment: today")
check(UsageText.moment(cal.date(byAdding: .hour, value: 19, to: noon)!, now: noon, calendar: cal) == "tomorrow at 07:00", "moment: tomorrow")
check(UsageText.moment(cal.date(byAdding: .day, value: 2, to: noon)!, now: noon, calendar: cal) == "on Sep 28 at 12:00", "moment: a date", UsageText.moment(cal.date(byAdding: .day, value: 2, to: noon)!, now: noon, calendar: cal))
check(UsageText.ago(t0.addingTimeInterval(-30), now: t0) == "just now" && UsageText.ago(t0.addingTimeInterval(-23 * 60), now: t0) == "23 min ago", "how long ago")

// --- the order of priority (.ordem)
// No order written: the order of old (the preferred one, then by name;
// Claude before GPT), each account with the key it goes by.
let noOrder = AIAccounts.discover(home: home)
check(noOrder.map(\.summary.order) == ["claude:spare", "claude:work", "gpt:principal"],
      "no order written: the order of old, each with its key", "\(noOrder.map(\.summary.order))")
check(noOrder.last?.alias == "main" && noOrder.last?.summary.order == "gpt:principal",
      "Codex's own login: shown as main, known to the helper as principal",
      "\(String(describing: noOrder.last?.summary))")
let orderFile = vault.appendingPathComponent(".ordem")
func order(_ text: String) { try! text.write(to: orderFile, atomically: true, encoding: .utf8) }
// Across services, a comment and a blank line, a key said twice, a key with
// no account.
order("# priority\n\ngpt:principal\nclaude:gone\nclaude:main\ngpt:principal\n")
let withOrder = AIAccounts.discover(home: home)
check(withOrder.map(\.alias) == ["main", "work", "spare"] && withOrder.map(\.engine) == [.codex, .claude, .claude],
      "order: GPT first, the merged account at one of its slots' places, the unnamed one last",
      "\(withOrder.map { "\($0.engine.orderPrefix):\($0.alias)" })")
let merged = withOrder.first { $0.key == "U1" }
check(merged?.orderKey == "claude:main", "merged: its key is the listed slot's", "\(String(describing: merged?.orderKey))")
check(withOrder.last?.orderKey == "claude:spare", "unnamed: its key is the slot it is shown under")
// A merged account sits at the EARLIER of its slots' places.
order("claude:spare\nclaude:main\ngpt:principal\nclaude:work\n")
let earlier = AIAccounts.discover(home: home)
check(earlier.map(\.summary.order) == ["claude:spare", "claude:main", "gpt:principal"],
      "merged: the earlier of its slots' places counts", "\(earlier.map(\.summary.order))")
order("claude:work\ngpt:principal\nclaude:main\n")
let earlier2 = AIAccounts.discover(home: home)
check(earlier2.first?.orderKey == "claude:work" && earlier2.first?.alias == "work",
      "merged: its key is the slot at the earlier place", "\(earlier2.map(\.summary.order))")
check(AIOrder.read(URL(fileURLWithPath: "/does/not/exist")).isEmpty, "no order file: nothing listed")
try? fm.removeItem(at: orderFile)

// --- other GPT logins (.codex-contas/<name>/auth.json)
let extras = home.appendingPathComponent(".codex-contas")
func extra(_ name: String, email: String, account: String) {
    let folder = extras.appendingPathComponent(name)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let token = "h." + b64url(["exp": exp, "https://api.openai.com/profile": ["email": email],
                               "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": account]]) + ".s"
    try! JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "account_id": account]])
        .write(to: folder.appendingPathComponent("auth.json"))
}
extra("team", email: "t@example.com", account: "ACC-T")
extra("alt", email: "alt@example.com", account: "ACC-A")
extra("copy", email: "c@example.com", account: "ACC")          // the main login again
try! fm.createDirectory(at: extras.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
try! fm.createDirectory(at: extras.appendingPathComponent("empty"), withIntermediateDirectories: true)
let gpts = AIAccounts.codexAccounts(home: home)
check(gpts.map(\.alias) == ["main", "alt", "team"],
      "GPT: the main login, then the others by name; a copy merges; a dotted or empty folder is left out",
      "\(gpts.map(\.alias))")
check(gpts.first?.aliases == ["main", "copy"] && gpts.first?.summary.slotNames == ["principal", "copy"],
      "GPT: a copy of the main login is the main one, known by both names",
      "\(String(describing: gpts.first?.aliases)) \(String(describing: gpts.first?.summary.slotNames))")
check(gpts.first?.isActive == true && gpts.dropFirst().allSatisfy { !$0.isActive }, "GPT: only the main one is in use")
let team = gpts.first { $0.alias == "team" }
check(team?.email == "t@example.com" && team?.accountHeader == "ACC-T" && team?.summary.order == "gpt:team",
      "another GPT login: its address, its workspace and the key gpt:<name>", "\(String(describing: team?.summary))")
let everything = AIAccounts.discover(home: home)
check(everything.map(\.summary.order) == ["claude:spare", "claude:work", "gpt:principal", "gpt:alt", "gpt:team"],
      "discovery: Claude, then GPT's main login and the others", "\(everything.map(\.summary.order))")
check(everything.first { $0.alias == "main" && $0.engine == .codex }?.summary.keys == ["gpt:principal", "gpt:copy"],
      "an account's keys: one for each slot")

// --- the files' signature (the two-second glance)
let signature0 = AIAccounts.signature(home: home)
check(signature0 == AIAccounts.signature(home: home), "signature: the same when nothing changes")
Thread.sleep(forTimeInterval: 0.01)
order("gpt:team\n")
let signature1 = AIAccounts.signature(home: home)
check(signature1 != signature0, "signature: changes with the order")
extra("fresh", email: "f@example.com", account: "ACC-F")
check(AIAccounts.signature(home: home) != signature1, "signature: changes with a new GPT login")
let beforeHidden = AIAccounts.signature(home: home)
try! "{}".write(to: vault.appendingPathComponent(".hidden.json"), atomically: true, encoding: .utf8)
check(AIAccounts.signature(home: home) == beforeHidden, "signature: a hidden file in the vault does not count")
try? fm.removeItem(at: orderFile)

// --- whether an account can take work
func summary(_ engine: AIEngine, _ name: String, active: Bool = false, warning: String? = nil,
             names: [String]? = nil, email: String? = nil, slots: [String]? = nil) -> AIAccountSummary {
    AIAccountSummary(engine: engine, key: "\(engine.orderPrefix)-\(name)", alias: name, aliases: names ?? [name],
                     email: email ?? "\(name)@example.com", plan: nil, isActive: active, isPreferred: false,
                     warning: warning, slots: slots)
}
func usage(_ account: AIAccountSummary, _ windows: [(String, Double)] = [], limit: Bool = false,
           read: Bool = true) -> AccountUsage {
    AccountUsage(account: account, reading: read ? UsageReading(
        windows: windows.map { UsageWindow(label: $0.0, title: $0.0, percent: $0.1, resetsAt: nil) },
        limitReached: limit) : nil)
}
check(usage(summary(.claude, "a"), read: false).isAvailable, "available: not measured yet")
check(usage(summary(.claude, "a"), [("5h", 94.9), ("7d", 50), ("Fable", 100)]).isAvailable,
      "available: 5h and 7d under 95 (a per-model window does not count)")
check(!usage(summary(.claude, "a"), [("5h", 95)]).isAvailable, "not available: 5h at 95%")
check(!usage(summary(.codex, "a"), [("7d", 99)]).isAvailable, "not available: 7d at 99%")
check(!usage(summary(.claude, "a"), [("5h", 10)], limit: true).isAvailable, "not available: at the limit")
check(!usage(summary(.claude, "a", warning: "login refused"), read: false).isAvailable,
      "not available: something wrong with the login")

// --- keep-ia, against the stand-in that logs what it is asked
let state = home.appendingPathComponent("state")
try! fm.createDirectory(at: state, withIntermediateDirectories: true)
let fake = ProcessInfo.processInfo.environment["FAKE_IA"]!
let fakeDir = ProcessInfo.processInfo.environment["FAKE_IA_DIR"]!
func helperCalls() -> [[String]] {
    ((try? String(contentsOfFile: fakeDir + "/calls.jsonl", encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["argv"] as? [String] }
}
func forgetHelperCalls() { try? fm.removeItem(atPath: fakeDir + "/calls.jsonl") }
check(AIHelper.path(environment: ["KEEP_IA_BIN": "/does/not/exist"], installed: fake) == nil,
      "helper: KEEP_IA_BIN at nothing is none, with no falling through to the installed one")
check(AIHelper.path(environment: ["KEEP_IA_BIN": "/var/empty"], installed: fake) == nil, "helper: KEEP_IA_BIN at a directory is none")
check(AIHelper.path(environment: ["KEEP_IA_BIN": fake], installed: "/does/not/exist") == fake, "helper: KEEP_IA_BIN at an executable is that one")
check(AIHelper.path(environment: [:], installed: fake) == fake, "helper: without KEEP_IA_BIN, the installed one")
check(AIHelper.path(environment: [:], installed: "/does/not/exist") == nil, "helper: with neither, none")
check(AIHelper.path(environment: [:], installed: fakeDir) == nil, "helper: an installed one that is a directory does not count")
check(AIHelper.path(environment: ["KEEP_AI_USAGE_HOME": "/x"], installed: fake) == nil,
      "helper: an app reading a made-up home does not ask the installed one, which acts on the real home")
check(AIHelper.path(environment: ["KEEP_AI_USAGE_HOME": "/x", "KEEP_IA_BIN": fake], installed: "/does/not/exist") == fake,
      "helper: a made-up home with KEEP_IA_BIN, that one")
check(AIHelper.installedPath(environment: ["HOME": "/x/y"]) == "/x/y/.local/bin/keep-ia",
      "helper: the installed one is looked for under HOME")
check(AIHelper.installedPath(environment: ["HOME": ""]) == NSHomeDirectory() + "/.local/bin/keep-ia"
      && AIHelper.installedPath(environment: [:]) == NSHomeDirectory() + "/.local/bin/keep-ia",
      "helper: with no HOME, the user's home")
check(AIHelper.isValidKey("claude:spare") && AIHelper.isValidKey("gpt:principal") && AIHelper.isValidKey(AIHelper.followOrder),
      "keys: the valid shapes")
for bad in ["claude:", "gpt:a b", "claude:a/b", "claude:a:b", "--para=x", "other:x", "claude:x\n"] {
    check(!AIHelper.isValidKey(bad), "key refused: \(bad.debugDescription)")
}
setenv("KEEP_IA_BIN", fake, 1)
// The stand-in reads the made-up home.
setenv("KEEP_AI_USAGE_HOME", home.path, 1)
setenv("KIT_KEEP_ESTADO", state.path, 1)
forgetHelperCalls()
if case .success(let moved) = AIHelper.moveOrder("claude:work", up: false) {
    check(moved.first == "claude:spare", "move: the answer is the new order", "\(moved)")
} else { check(false, "move: ok") }
check(helperCalls().last == ["ordem", "mover", "claude:work", "baixo", "--json"], "move: the arguments", "\(helperCalls())")
forgetHelperCalls()
if case .failure(let p) = AIHelper.moveOrder("claude:a b", up: true) {
    check(p.reason == "invalid-key" && helperCalls().isEmpty, "move: a bad key never reaches the helper")
} else { check(false, "move: a bad key") }
if case .failure = AIHelper.moveOrder(AIHelper.followOrder, up: true) {
    check(helperCalls().isEmpty, "move: claude:ordem is not an account in the order")
} else { check(false, "move: claude:ordem") }
forgetHelperCalls()
if case .success(let done) = AIHelper.switchAccount(workspace: "-odd ws", tab: 7, to: "gpt:team", interrupt: false) {
    check(done.contains("gpt:team"), "switch: ok, with what was done", done)
} else { check(false, "switch: ok") }
check(helperCalls().last == ["trocar", "--ws=-odd ws", "--aba=7", "--para=gpt:team", "--json"],
      "switch: values inside their options, a workspace with a dash and a space", "\(helperCalls())")
try! "".write(toFile: fakeDir + "/busy", atomically: true, encoding: .utf8)
if case .failure(let p) = AIHelper.switchAccount(workspace: "w", tab: 2, to: "claude:spare", interrupt: false) {
    check(p.reason == "ocupada" && p.detail == "The tab is in the middle of an answer.",
          "switch: a busy tab comes back with the helper's reason and words", "\(p)")
} else { check(false, "switch: busy") }
if case .success = AIHelper.switchAccount(workspace: "w", tab: 2, to: "claude:spare", interrupt: true) {
    check(helperCalls().last == ["trocar", "--ws=w", "--aba=2", "--para=claude:spare", "--interromper", "--json"],
          "switch: --interromper", "\(helperCalls())")
} else { check(false, "switch: interrupting") }
try? fm.removeItem(atPath: fakeDir + "/busy")
forgetHelperCalls()
if case .failure(let p) = AIHelper.switchAccount(workspace: "w", tab: 2, to: "claude:x/y", interrupt: false) {
    check(p.reason == "invalid-key" && helperCalls().isEmpty, "switch: a bad key refused before anything runs")
} else { check(false, "switch: a bad key") }
// Signing in: the stand-in opens the tab with the client it is given, here
// one that only says its number.
let fakeClient = fakeDir + "/fake-keep.sh"
try! "#!/bin/sh\necho \"$2: opened tab 7\"\n".write(toFile: fakeClient, atomically: true, encoding: .utf8)
chmod(fakeClient, 0o755)
setenv("FAKE_IA_KEEP", fakeClient, 1)
if case .success(let opened) = AIHelper.signIn(.gpt, workspace: "home") {
    check(opened.workspace == "home" && opened.tab == 7, "sign in: the workspace and the tab", "\(opened)")
} else { check(false, "sign in: ok") }
check(helperCalls().last == ["entrar", "gpt", "--ws=home", "--json"], "sign in: the arguments", "\(helperCalls())")
check(fm.fileExists(atPath: home.appendingPathComponent(".codex-contas/new/auth.json").path),
      "sign in (stand-in): the new login is on disk")
// The deadline: a helper too slow is stopped at it.
AIHelper.timeScale = 0.2
try! "5".write(toFile: fakeDir + "/slow", atomically: true, encoding: .utf8)
let t1 = Date()
if case .failure(let p) = AIHelper.moveOrder("claude:spare", up: true) {
    check(Date().timeIntervalSince(t1) < 4 && p.detail.contains("took longer than 2 s"),
          "deadline: a slow helper is cut off after ~2 s", p.detail)
} else { check(false, "deadline: should have failed") }
try? fm.removeItem(atPath: fakeDir + "/slow")
AIHelper.timeScale = 1
// An answer that is not the helper's kind.
let broken = fakeDir + "/broken.sh"
try! "#!/bin/sh\necho 'not json'\nexit 1\n".write(toFile: broken, atomically: true, encoding: .utf8)
chmod(broken, 0o755)
setenv("KEEP_IA_BIN", broken, 1)
if case .failure(let p) = AIHelper.switchAccount(workspace: "w", tab: 1, to: "claude:spare", interrupt: false) {
    check(p.reason == "unreadable" && p.detail.contains("Unreadable answer from keep-ia"), "an unreadable answer: said", p.detail)
} else { check(false, "an unreadable answer") }
setenv("KEEP_IA_BIN", "/does/not/exist", 1)
if case .failure(let p) = AIHelper.moveOrder("claude:spare", up: true) {
    check(p.reason == "no-helper", "no helper: nothing runs")
} else { check(false, "no helper") }
check(!fm.fileExists(atPath: fakeDir + "/installed-helper-called"),
      "the installed helper, the made-up HOME's canary, was never asked",
      (try? String(contentsOfFile: fakeDir + "/installed-helper-called", encoding: .utf8)) ?? "")

try? fm.removeItem(at: home)
print("\(cases - failures)/\(cases) ok")
exit(failures == 0 ? 0 : 1)
