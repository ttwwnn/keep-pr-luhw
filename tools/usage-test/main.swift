import Foundation
// The model test of AIUsage.swift (the usage footer's facts), run by
// tools/usage-test.sh. Foundation only: no app, no network, no real logins.

var failures = 0
var cases = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
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

try? fm.removeItem(at: home)
print("\(cases - failures)/\(cases) ok")
exit(failures == 0 ? 0 : 1)
