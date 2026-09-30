import Foundation

// The AI accounts this Mac is signed in to, and how much of each one's
// allowance is spent — the facts behind the sidebar's usage footer.
//
// Foundation only, and no state: everything here is a function of files on
// disk and bytes off the wire, so it can be proved with a bare `swiftc` and a
// test main, the way `ClaudeActivity.read` was. The monitor that schedules
// the reads, and the view that draws them, live in the UI layer.
//
// Reading only. The credentials are the ones Claude Code and Codex already
// keep, and nothing here renews one: a refresh token is single use on both
// services, so a renewal made from here would leave every tab holding a
// token the server had just retired, and every tab would be logged out. A
// token past its life is reported, not fixed; the tools that own it renew it.

/// Which service an account belongs to.
enum AIEngine: String, Equatable, Codable {
    case claude
    case codex

    /// How the footer names the service: the product, not the vendor.
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "GPT"
        }
    }

    /// How the order of priority and `keep-ia` name the service — `claude:`
    /// and `gpt:`, the product again, since Codex is only the program that
    /// runs it.
    var orderPrefix: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "gpt"
        }
    }

    /// The key one of its accounts goes by in the order and to the helper:
    /// `claude:spare`, `gpt:principal`.
    func key(_ alias: String) -> String { "\(orderPrefix):\(alias)" }
}

/// One signed-in account, as read from disk.
///
/// The token travels with it from discovery to the request and no further:
/// nothing published to the view carries one (`AIAccountSummary` is what
/// does).
struct AIAccount: Equatable {
    let engine: AIEngine
    /// What the account is known by across slots: the service's own id when
    /// there is one, so two slots holding the same login are one account.
    let key: String
    /// The name it is shown under — the vault's slot name for Claude, "main"
    /// for Codex's own login, and a folder's name for another Codex login.
    let alias: String
    /// Every slot name that turned out to hold this same account.
    let aliases: [String]
    let email: String?
    let plan: String?
    /// The account the tabs are running on now (the vault's `.ativa`).
    let isActive: Bool
    /// The first one tried when an account is picked (`.preferida`).
    let isPreferred: Bool
    let token: String?
    /// The workspace the ChatGPT request is about; Claude has none.
    let accountHeader: String?
    let expiresAt: Date?
    /// Something known to be wrong with the login itself, said on its line
    /// whether or not a reading comes back.
    let warning: String?
    /// The key that stands for it in the order of priority (`AIOrder`): the
    /// slot found earliest there, or the one it is shown under when none is
    /// listed. Nil until the order has been read.
    var orderKey: String?
    /// The name each slot goes by in the order of priority and to
    /// `keep-ia`, where it is not the name shown: Codex's own login is shown
    /// as "main" and is `principal` there. Nil when every slot goes by the
    /// name it is shown under.
    var slots: [String]?

    /// Each slot's name in the order and to the helper, in `aliases`' order.
    var slotNames: [String] { slots ?? aliases }

    /// That name, for the slot the account is shown under.
    var slot: String { slotNames[aliases.firstIndex(of: alias) ?? 0] }

    var summary: AIAccountSummary {
        AIAccountSummary(
            engine: engine, key: key, alias: alias, aliases: aliases, email: email,
            plan: plan, isActive: isActive, isPreferred: isPreferred, warning: warning,
            orderKey: orderKey ?? engine.key(slot), hasToken: token != nil, slots: slots)
    }
}

/// An account with the secret taken out: what the view is allowed to hold.
struct AIAccountSummary: Equatable, Codable {
    func isUsed(by selectedAccount: String?) -> Bool {
        guard let selectedAccount else { return false }
        if selectedAccount == "claude:ordem" { return engine == .claude && isActive }
        return keys.contains(selectedAccount)
    }

    let engine: AIEngine
    let key: String
    let alias: String
    let aliases: [String]
    let email: String?
    let plan: String?
    let isActive: Bool
    let isPreferred: Bool
    let warning: String?
    /// Optional, all three, so that a footer saved by a build that had none
    /// of them still decodes: a missing key is nil, never an error that
    /// throws the whole saved footer away.
    var orderKey: String? = nil
    /// Whether a token was found for it — kept apart from the token itself,
    /// which never leaves the monitor's background work.
    var hasToken: Bool? = nil
    /// As on `AIAccount`.
    var slots: [String]? = nil

    /// The line's stable identity: the same account keeps its place and its
    /// fold across reads.
    var id: String { "\(engine.rawValue):\(key)" }

    /// "Claude · spare": which service, and the name the slot is shown under.
    var name: String { "\(engine.title) · \(alias)" }

    var slotNames: [String] { slots ?? aliases }
    var slot: String { slotNames[aliases.firstIndex(of: alias) ?? 0] }

    /// The key the helper is told when this account moves in the order.
    var order: String { orderKey ?? engine.key(slot) }

    /// Every key that names this account, one per slot: a tab kept on any of
    /// them is on this account.
    var keys: [String] { slotNames.map(engine.key) }
}

// MARK: - finding the accounts

enum AIAccounts {
    /// Every account, in the order of priority (`AIOrder`): the one work goes
    /// to first, first. Where the order says nothing — no order written yet,
    /// or an account it has not heard of — Claude's vault comes before Codex,
    /// as it always has.
    ///
    /// `home` is the user's home, or a stand-in a test points at: the vault is
    /// `.claude/contas`, the Codex logins `.codex/auth.json` and
    /// `.codex-contas/<name>/auth.json`.
    static func discover(home: URL) -> [AIAccount] {
        let vault = home.appendingPathComponent(".claude/contas")
        return AIOrder.sorted(
            claude(vault: vault) + codexAccounts(home: home),
            by: AIOrder.read(AIOrder.file(home: home)))
    }

    /// The accounts in the Claude account vault: one JSON file per slot (a
    /// copy of a Claude Code login, its name under `apelido`), `.ativa`
    /// naming the slot the tabs run on and `.preferida` the one tried first.
    /// The vault's file and key names are its own, and are read as they are.
    ///
    /// Two slots holding the same login are one account: its allowance is
    /// one allowance, and showing it twice would read as twice the room. The
    /// freshest token of the pair is the one kept.
    static func claude(vault: URL) -> [AIAccount] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: nil)) ?? []
        let active = slotName(vault.appendingPathComponent(".ativa"))
        let preferred = slotName(vault.appendingPathComponent(".preferida"))

        var slots: [AIAccount] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            guard let data = try? Data(contentsOf: file),
                  let slot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let alias = (slot["apelido"] as? String).flatMap(nonEmpty)
                ?? String(name.dropLast(".json".count))
            let oauth = (slot["credenciais"] as? [String: Any])?["claudeAiOauth"] as? [String: Any]
            let email = (slot["email"] as? String).flatMap(nonEmpty)
                ?? ((slot["oauthAccount"] as? [String: Any])?["emailAddress"] as? String)
            let uuid = (slot["accountUuid"] as? String).flatMap(nonEmpty)
                ?? ((slot["oauthAccount"] as? [String: Any])?["accountUuid"] as? String)
            let expires = (oauth?["expiresAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
            // The vault's mark for a login the server refused to renew: the
            // account is gone until somebody signs in again, whatever its
            // access token still says for its last hours.
            let dead = (slot["refreshMorto"] as? String).flatMap(nonEmpty) != nil
            slots.append(AIAccount(
                engine: .claude,
                key: uuid ?? email ?? alias,
                alias: alias,
                aliases: [alias],
                email: email,
                plan: claudePlan(
                    tier: oauth?["rateLimitTier"] as? String,
                    subscription: oauth?["subscriptionType"] as? String),
                isActive: alias == active,
                isPreferred: alias == preferred,
                token: (oauth?["accessToken"] as? String).flatMap(nonEmpty),
                accountHeader: nil,
                expiresAt: expires,
                warning: dead ? "login refused: sign in again with /login" : nil))
        }

        // A fixed order, so an account switch does not shuffle the footer:
        // the preferred account first, then by name. What the order of
        // priority says is laid over this by `discover`; this is what is left
        // when it says nothing.
        return merge(slots).sorted {
            if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
            return $0.alias < $1.alias
        }
    }

    /// One account per login, in the order the slots were read.
    ///
    /// Two slots holding the same login are one account — Claude's vault
    /// under two names, or a Codex login copied into a second folder — and
    /// the freshest token of them is the one kept. It is shown under the
    /// name the tabs know it by, when one of its slots is the active one.
    static func merge(_ slots: [AIAccount]) -> [AIAccount] {
        var merged: [AIAccount] = []
        for slot in slots {
            guard let at = merged.firstIndex(where: {
                $0.engine == slot.engine && $0.key == slot.key
            }) else {
                merged.append(slot)
                continue
            }
            let held = merged[at]
            let fresher = (slot.expiresAt ?? .distantPast) > (held.expiresAt ?? .distantPast)
                ? slot : held
            let shown = slot.isActive ? slot : held
            merged[at] = AIAccount(
                engine: held.engine,
                key: held.key,
                alias: shown.alias,
                aliases: held.aliases + slot.aliases,
                email: held.email ?? slot.email,
                plan: held.plan ?? slot.plan,
                isActive: held.isActive || slot.isActive,
                isPreferred: held.isPreferred || slot.isPreferred,
                token: fresher.token,
                accountHeader: fresher.accountHeader ?? held.accountHeader ?? slot.accountHeader,
                expiresAt: fresher.expiresAt,
                warning: fresher.warning,
                slots: held.slots == nil && slot.slots == nil ? nil : held.slotNames + slot.slotNames)
        }
        return merged
    }

    /// Every Codex login: `.codex/auth.json`, the one Codex itself uses and
    /// so the "main" one, then each folder of `.codex-contas` holding one —
    /// the other logins `keep-ia` makes, one `CODEX_HOME` each — by name. A
    /// folder whose login is the main one's own is the main one (`merge`).
    static func codexAccounts(home: URL) -> [AIAccount] {
        var found = [codex(auth: home.appendingPathComponent(".codex/auth.json"))].compactMap { $0 }
        let extras = home.appendingPathComponent(".codex-contas")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: extras.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let auth = extras.appendingPathComponent(name).appendingPathComponent("auth.json")
            if let account = codex(auth: auth, slot: name) { found.append(account) }
        }
        return merge(found)
    }

    /// The name Codex's own login goes by in the order of priority and to
    /// `keep-ia`; it is shown as "main".
    static let codexOwnSlot = "principal"

    /// A Codex login, if it is a ChatGPT one. An API key has no subscription
    /// window to show. The one in `.codex` is shown as "main"; another is
    /// named after its folder.
    static func codex(auth: URL, slot: String = codexOwnSlot) -> AIAccount? {
        guard let data = try? Data(contentsOf: auth),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = file["tokens"] as? [String: Any],
              let access = (tokens["access_token"] as? String).flatMap(nonEmpty)
        else { return nil }
        let claims = jwtClaims(access)
        let identity = (tokens["id_token"] as? String).flatMap(jwtClaims)
        let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
        let authClaims = (claims?["https://api.openai.com/auth"] as? [String: Any])
            ?? (identity?["https://api.openai.com/auth"] as? [String: Any])
        let email = (profile?["email"] as? String).flatMap(nonEmpty)
            ?? (identity?["email"] as? String).flatMap(nonEmpty)
        let accountID = (tokens["account_id"] as? String).flatMap(nonEmpty)
            ?? (authClaims?["chatgpt_account_id"] as? String)
        let expires = (claims?["exp"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        // Codex's own login is the service's main account; the address is
        // written under it in the footer. It is the one a tab runs on unless
        // it was started on another, so it is the one "in use".
        let own = slot == codexOwnSlot
        let alias = own ? "main" : slot
        return AIAccount(
            engine: .codex,
            key: accountID ?? email ?? (own ? "codex" : "codex-\(slot)"),
            alias: alias,
            aliases: [alias],
            email: email,
            plan: (authClaims?["chatgpt_plan_type"] as? String).map(capitalizedPlan),
            isActive: own,
            isPreferred: false,
            token: access,
            accountHeader: accountID,
            expiresAt: expires,
            warning: nil,
            slots: own ? [codexOwnSlot] : nil)
    }

    /// "default_claude_max_20x" reads as "Max 20x"; a tier this does not know
    /// falls back on the subscription's own name.
    static func claudePlan(tier: String?, subscription: String?) -> String? {
        if let tier, let range = tier.range(of: #"max_(\d+x)"#, options: .regularExpression) {
            return "Max " + String(tier[range].dropFirst("max_".count))
        }
        return subscription.flatMap(nonEmpty).map(capitalizedPlan)
    }

    private static func capitalizedPlan(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    private static func slotName(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(nonEmpty)
    }

    /// The claims of a JWT, read without checking its signature: this only
    /// decides what to show and when not to bother asking, and the server
    /// checks the token on every request anyway.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: noticing a change

    /// What the files the logins live in look like, as cheaply as asking:
    /// each slot of the vault and the three names beside them (`.ativa`,
    /// `.preferida`, `.ordem`), Codex's login, and each extra one. Different
    /// from the last time means worth reading again — a login added or
    /// renewed, an account switched, the order changed by `keep-ia`.
    ///
    /// Stat calls and two directory listings; no file is opened. A login made
    /// with the footer's "+" is noticed by this within a couple of seconds,
    /// rather than at the next five-minute reading.
    static func signature(home: URL) -> [String] {
        let files = FileManager.default
        var parts: [String] = []
        let vault = home.appendingPathComponent(".claude/contas")
        for name in ((try? files.contentsOfDirectory(atPath: vault.path)) ?? []).sorted() {
            let slot = name.hasSuffix(".json") && !name.hasPrefix(".")
            guard slot || [".ativa", ".preferida", ".ordem"].contains(name) else { continue }
            parts.append(name + " " + stamp(vault.appendingPathComponent(name)))
        }
        parts.append("codex " + stamp(home.appendingPathComponent(".codex/auth.json")))
        let extras = home.appendingPathComponent(".codex-contas")
        for name in ((try? files.contentsOfDirectory(atPath: extras.path)) ?? []).sorted()
        where !name.hasPrefix(".") {
            let auth = extras.appendingPathComponent(name).appendingPathComponent("auth.json")
            parts.append("codex/\(name) " + stamp(auth))
        }
        return parts
    }

    /// A file as `stat` has it: which file (the inode — whoever writes these
    /// replaces them whole), when, and how long. "-" when it is not there.
    static func stamp(_ file: URL) -> String {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return "-" }
        let modified = info.st_mtimespec
        return "\(info.st_ino) \(modified.tv_sec).\(modified.tv_nsec) \(info.st_size)"
    }
}

// MARK: - the order of priority

/// The order of priority among the accounts, across both services: which
/// one work goes to first.
///
/// `~/.claude/contas/.ordem`, one key a line — `claude:<slot>`, `gpt:<name>`.
/// Only `keep-ia` writes it (the footer's arrows ask it to); this reads it,
/// and forgivingly, as the helper does: blank lines and `#` lines are
/// nothing, a key said twice counts where it is first said, a key whose
/// account is gone is passed over, and an account the order does not mention
/// yet goes after the ones it does, in the footer's order of old. So an
/// order that was never written leaves the footer exactly as it was before
/// there was one.
enum AIOrder {
    static func file(home: URL) -> URL {
        home.appendingPathComponent(".claude/contas/.ordem")
    }

    static func read(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var keys: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), seen.insert(line).inserted else { continue }
            keys.append(line)
        }
        return keys
    }

    /// The accounts in the order's order, each given the key that stands
    /// for it there.
    ///
    /// An account held in two slots sits at the earlier place of the two,
    /// and is known in the order by that slot's name — the one the helper
    /// will be moving when the arrows move it. The ones not mentioned keep the
    /// order they arrived in, after all the others.
    static func sorted(_ accounts: [AIAccount], by order: [String]) -> [AIAccount] {
        var rank: [String: Int] = [:]
        for (place, key) in order.enumerated() where rank[key] == nil { rank[key] = place }
        var placed: [(place: Int, account: AIAccount)] = []
        var rest: [AIAccount] = []
        for var account in accounts {
            let listed = account.slotNames.compactMap { slot -> (place: Int, key: String)? in
                let key = account.engine.key(slot)
                return rank[key].map { (place: $0, key: key) }
            }
            if let first = listed.min(by: { $0.place < $1.place }) {
                account.orderKey = first.key
                placed.append((first.place, account))
            } else {
                account.orderKey = account.engine.key(account.slot)
                rest.append(account)
            }
        }
        // Stable: two accounts never share a place, but the sort is asked to
        // keep the incoming order all the same.
        let ordered = placed.enumerated().sorted {
            ($0.element.place, $0.offset) < ($1.element.place, $1.offset)
        }.map(\.element.account)
        return ordered + rest
    }
}

// MARK: - one account's line

/// One account's place in the footer: who it is, and the last it said.
///
/// Here rather than beside the view, so that what the menus decide from it
/// (`AIChoices`) can be proved without an app.
struct AccountUsage: Identifiable, Equatable, Codable {
    let account: AIAccountSummary
    /// The last reading that came back, kept through later failures: an old
    /// figure marked as old says more than a blank.
    var reading: UsageReading?
    var measuredAt: Date?
    /// Why the latest attempt brought nothing back, when it did not.
    var problem: String?

    init(
        account: AIAccountSummary, reading: UsageReading? = nil, measuredAt: Date? = nil,
        problem: String? = nil
    ) {
        self.account = account
        self.reading = reading
        self.measuredAt = measuredAt
        self.problem = problem
    }

    var id: String { account.id }

    /// Whether this account can take work now, as the helper judges it:
    /// nothing known to be wrong with its login, and not at its limit. The
    /// service refuses at 100% of the five-hour or the weekly window, and
    /// only there does an account leave the order. From 95% the helper moves
    /// work on ahead of the limit, but only to an account with room; one
    /// past 95% still takes work, and taking it for one at its limit sent a
    /// new tab to GPT while a Claude account still answered.
    /// One not measured yet is given the benefit of the doubt.
    var isAvailable: Bool {
        guard account.warning == nil else { return false }
        guard let reading else { return true }
        if reading.limitReached { return false }
        return !reading.windows.contains { ($0.label == "5h" || $0.label == "7d") && $0.percent >= 100 }
    }
}

private func nonEmpty(_ text: String) -> String? {
    text.isEmpty ? nil : text
}

// MARK: - reading the answers

/// One allowance window: a bar in the footer.
struct UsageWindow: Equatable, Codable {
    /// The short name beside the bar ("5h", "7d", "Fable").
    let label: String
    /// The long name, for the tooltip ("Session (5h)").
    let title: String
    /// Spent, from 0 to 100 — both services answer in percent.
    let percent: Double
    let resetsAt: Date?
}

/// Everything one answer says about one account.
struct UsageReading: Equatable, Codable {
    let windows: [UsageWindow]
    /// The service says the account is at its limit now — by its general
    /// windows. A per-model window, extra credits or an additional limit at
    /// 100% show red on their own bar; the account itself still works.
    let limitReached: Bool
}

enum UsageParse {
    /// `GET /api/oauth/usage`, as Claude Code itself reads it.
    ///
    /// `five_hour` and `seven_day` are the two windows every plan has, with
    /// `utilization` already in percent (1.0 is one percent, not all of it).
    /// A per-model weekly window arrives in `limits` as `weekly_scoped` with
    /// the model's name; the older `seven_day_opus` and `seven_day_sonnet`
    /// keys are read only when that list names none. Extra credits show only
    /// when they are switched on and have a figure.
    static func claude(_ data: Data) -> UsageReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let limits = (root["limits"] as? [[String: Any]]) ?? []

        func fromLimits(_ kind: String) -> [String: Any]? {
            limits.first { ($0["kind"] as? String) == kind }
        }

        var windows: [UsageWindow] = []
        var reached = false

        func add(
            _ label: String, _ title: String, window: [String: Any]?, limit: [String: Any]?,
            general: Bool = false
        ) {
            let percent = number(window?["utilization"]) ?? number(limit?["percent"])
            guard let percent else { return }
            let resets = date(window?["resets_at"]) ?? date(limit?["resets_at"])
            windows.append(UsageWindow(label: label, title: title, percent: percent, resetsAt: resets))
            if general, percent >= 100 { reached = true }
        }

        add("5h", "Session (5h)",
            window: root["five_hour"] as? [String: Any], limit: fromLimits("session"), general: true)
        add("7d", "Weekly (7 days)",
            window: root["seven_day"] as? [String: Any], limit: fromLimits("weekly_all"), general: true)

        let scoped = limits.filter { ($0["kind"] as? String) == "weekly_scoped" }
        for limit in scoped {
            // Scoped to a model, or to a surface (Claude Code, the app…).
            let scope = limit["scope"] as? [String: Any]
            let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String).flatMap(nonEmpty)
            let surface = ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                .flatMap(nonEmpty)
            let name = model ?? surface ?? "model"
            add(name, "Weekly — \(name)", window: nil, limit: limit)
        }
        if scoped.isEmpty {
            add("Opus", "Weekly — Opus", window: root["seven_day_opus"] as? [String: Any], limit: nil)
            add("Sonnet", "Weekly — Sonnet",
                window: root["seven_day_sonnet"] as? [String: Any], limit: nil)
        }
        if let extra = root["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            add("Extra", "Extra credits this month", window: extra, limit: nil)
        }

        guard !windows.isEmpty else { return nil }
        return UsageReading(windows: windows, limitReached: reached)
    }

    /// `GET /backend-api/wham/usage`, as Codex reads it.
    ///
    /// Windows are named by their length, which the answer states in seconds:
    /// a plan's windows are not fixed (a Pro account today has only the
    /// weekly one) and a label taken from position would lie when they move.
    static func codex(_ data: Data) -> UsageReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var windows: [UsageWindow] = []
        var reached = false

        func take(_ limit: [String: Any]?, prefix: String?) {
            guard let limit else { return }
            // Only the plan's own limit blocks the account; an additional
            // one blocks what it is about.
            if prefix == nil, (limit["limit_reached"] as? Bool) == true { reached = true }
            for key in ["primary_window", "secondary_window"] {
                guard let window = limit[key] as? [String: Any],
                      let percent = number(window["used_percent"])
                else { continue }
                let seconds = number(window["limit_window_seconds"])
                let (label, title) = windowName(seconds: seconds)
                let resets = number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                windows.append(UsageWindow(
                    label: prefix.map { "\($0) \(label)" } ?? label,
                    title: prefix.map { "\(title) — \($0)" } ?? title,
                    percent: percent,
                    resetsAt: resets))
                if prefix == nil, percent >= 100 { reached = true }
            }
        }

        take(root["rate_limit"] as? [String: Any], prefix: nil)
        for extra in (root["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String)
            take((extra["rate_limit"] as? [String: Any]) ?? extra, prefix: name ?? "extra")
        }

        guard !windows.isEmpty else { return nil }
        return UsageReading(windows: windows, limitReached: reached)
    }

    /// "5h" for five hours, "7d" for a week, and the plain length otherwise.
    static func windowName(seconds: Double?) -> (String, String) {
        guard let seconds, seconds > 0 else { return ("window", "Window") }
        let hours = Int((seconds / 3600).rounded())
        switch hours {
        case 5: return ("5h", "Session (5h)")
        case 168: return ("7d", "Weekly (7 days)")
        case let h where h % 24 == 0: return ("\(h / 24)d", "\(h / 24)-day window")
        default: return ("\(hours)h", "\(hours)-hour window")
        }
    }

    /// A figure, whichever way the JSON wrote it. A boolean is not one: and
    /// the test for it is Core Foundation's, because Swift answers `is Bool`
    /// for any NSNumber holding 0 or 1 — which dropped every window sitting
    /// at exactly 0% or 1% from the footer.
    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// ISO 8601 as both services write it — the Claude one with six digits
    /// of fraction and a `+00:00` offset, which the formatter's fractional
    /// option does not always take: the fraction is dropped before parsing,
    /// a reset time has no use for microseconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let trimmed = text.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}

// MARK: - asking

enum UsageEndpoint {
    static let claude = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let codex = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// The request for one account, or nil when there is nothing to send.
    ///
    /// `environment` may point either service at a stand-in, and only at one
    /// on this machine (`http://127.0.0.1:<port>`): a test must be able to
    /// feed the footer without a real token going anywhere, and a stray
    /// variable must not be able to send a real one elsewhere.
    static func request(
        for account: AIAccount,
        environment: [String: String],
        clientVersions: (claude: String, codex: String)
    ) -> URLRequest? {
        guard let token = account.token else { return nil }
        switch account.engine {
        case .claude:
            var request = URLRequest(url: target(claude, environment["KEEP_AI_USAGE_CLAUDE_URL"]))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            // Without a CLI's user agent the endpoint's front door answers
            // 403, or 429 for ever.
            request.setValue(
                "claude-cli/\(clientVersions.claude) (external, cli)",
                forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            return request
        case .codex:
            var request = URLRequest(url: target(codex, environment["KEEP_AI_USAGE_CODEX_URL"]))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let workspace = account.accountHeader {
                request.setValue(workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.setValue("codex_cli_rs/\(clientVersions.codex)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            return request
        }
    }

    private static func target(_ real: URL, _ override: String?) -> URL {
        guard let override, let url = URL(string: override),
              url.scheme == "http", url.host == "127.0.0.1"
        else { return real }
        return url
    }

    /// The versions to name in the user agents, read off the installed
    /// tools: Claude Code's launcher links to `versions/<x.y.z>`, Codex's to
    /// `releases/<x.y.z>-<platform>/bin/codex`. A tool that is not there, or
    /// laid out differently, gets a version that answered when this was
    /// written.
    static func installedVersions(home: URL) -> (claude: String, codex: String) {
        func resolved(_ path: String) -> String {
            home.appendingPathComponent(path).resolvingSymlinksInPath().path
        }
        func version(in path: String) -> String? {
            guard let range = path.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
            else { return nil }
            return String(path[range])
        }
        return (
            version(in: resolved(".local/bin/claude")) ?? "2.1.283",
            version(in: resolved(".local/bin/codex")) ?? "0.157.0"
        )
    }
}

// MARK: - saying it

enum UsageText {
    /// "17%", whole numbers: a tenth of a percent of a weekly allowance is
    /// not something anyone acts on.
    static func percent(_ value: Double) -> String {
        "\(Int(max(0, min(999, value)).rounded()))%"
    }

    /// How long until a window starts over, in the fewest characters that
    /// still say it: "41min", "4h10", "1d13h".
    static func until(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(minutes)min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h" + String(format: "%02d", rest)
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d\(restHours)h"
    }

    /// The reset as a moment, for the tooltip: "today at 01:50", "tomorrow at
    /// 07:00", "on Sep 28 at 07:00".
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = DateFormatter()
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow at \(time)" }
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "MMM d"
        return "on \(clock.string(from: date)) at \(time)"
    }

    /// "just now", "3 min ago", "2h ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }

    /// A warning from 75, and critical from 90: early enough to move to
    /// another account before this one runs out.
    enum Level: Equatable { case normal, attention, critical }

    static func level(_ percent: Double) -> Level {
        if percent >= 90 { return .critical }
        if percent >= 75 { return .attention }
        return .normal
    }
}
