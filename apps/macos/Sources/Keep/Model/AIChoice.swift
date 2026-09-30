import Foundation

// Which AI and which account each tab runs on, and the menu that changes it.
//
// Foundation only, like AIUsage.swift, so it is proved with a bare `swiftc`
// and a test main (tools/usage-test.sh). `keep-ia`, the helper outside the
// app, decides and does everything here that touches an account or a
// credential; what lives in this file is reading what the helper wrote down,
// and deciding what the menu offers.

/// What a tab is running, as far as its AI menu is concerned.
///
/// Read from the name of the process holding its terminal (the daemon's
/// `command`). A shell is somewhere an AI can be started; Claude Code and
/// Codex can be moved to another account; anything else is somebody else's
/// program, and the menu keeps its hands off it.
enum AIProgramKind: Equatable {
    case shell
    case claude
    case codex
    /// Another program, by name: the menu says so and offers nothing.
    case other(String)
    /// Nothing said — a daemon too old to name the process. Not held against
    /// the tab: the helper looks for itself before it touches anything.
    case unknown

    init(command: String) {
        // A login shell is named with a dash in front of it.
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        if name.isEmpty {
            self = .unknown
        } else if Self.shells.contains(name) {
            self = .shell
        } else if name == "claude" || Self.isVersionNumber(name) {
            // Claude Code's own installer keeps each release as a file named
            // after its version, and the process is called what the file is.
            self = .claude
        } else if name == "codex" {
            self = .codex
        } else {
            self = .other(name)
        }
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu"]

    private static func isVersionNumber(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Whether the menu may do anything to the tab.
    var allowsChoice: Bool {
        if case .other = self { return false }
        return true
    }

    /// Whether an AI is what runs there, so an account the helper wrote down
    /// for the tab is still the tab's: once the tab is back at its shell,
    /// that account is history.
    var runsAI: Bool {
        switch self {
        case .claude, .codex, .unknown: return true
        case .shell, .other: return false
        }
    }
}

/// One line of the "ia" list in the helper's `retrato.json`: an AI running in
/// a tab, and the account it runs on. The file's names are the helper's own.
struct AITabAccount: Equatable {
    let workspace: String
    let tab: UInt32
    /// "claude" or "codex".
    let agent: String
    /// `claude:ordem`, `claude:<slot>` or `gpt:<name>`.
    let key: String
    /// "exato" when the helper tied the process to the tab for certain,
    /// "provavel" when it had to reason its way there.
    let link: String
}

/// The account each tab runs on, as the helper last wrote it down.
///
/// The helper writes every tab's conversation — and its account — to
/// `retrato.json` every half minute and straight after each change it makes.
/// Read here the way `NameStore` reads names.json: again only when the file
/// has changed, and only when it was written for the daemon that is running,
/// since tab numbers are that daemon's and a file kept for another one would
/// put its accounts on unrelated tabs.
///
/// A change the app itself just asked for is shown before the helper writes
/// it down (`note`), and for as long as nothing newer than the moment it was
/// made has been written.
@MainActor
final class AITabAccounts {
    private var entries: [String: AITabAccount] = [:]
    /// Accounts the helper has just said yes to, by tab, and when (unix ms).
    private var notes: [String: (key: String, at: Double)] = [:]
    /// When the file in hand was written, as it says (unix ms).
    private var written: Double = 0
    private let file: URL
    /// The file and the daemon it was last read against.
    private var seen: String?
    private var seenDaemon: Date?

    init(directory: URL? = nil) {
        file = (directory ?? Self.directory()).appendingPathComponent("retrato.json")
    }

    /// `KIT_KEEP_ESTADO`, as the helper itself reads it, else the helper's
    /// own place. A test sets it; the suites point it at nothing.
    nonisolated static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let named = environment["KIT_KEEP_ESTADO"], !named.isEmpty {
            return URL(fileURLWithPath: named, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/kit-keep", isDirectory: true)
    }

    /// Read the file again if it changed, or if the daemon did. True when
    /// what some tab shows has changed.
    func reload(daemonStart: Date?) -> Bool {
        let before = shown
        if seenDaemon != daemonStart { notes.removeAll(); seenDaemon = daemonStart }
        let now = AIAccounts.stamp(file) + " @" + (daemonStart.map { "\($0.timeIntervalSince1970)" } ?? "-")
        guard now != seen else { return false }
        seen = now
        let read = (try? Data(contentsOf: file)).flatMap { Self.parse($0, daemonStart: daemonStart) }
        entries = Dictionary(
            (read?.entries ?? []).map { (Self.id($0.workspace, $0.tab), $0) },
            uniquingKeysWith: { first, _ in first })
        written = read?.written ?? 0
        // What the helper wrote after a change was made is the word on it
        // now, whatever it says.
        notes = notes.filter { $0.value.at > written }
        return shown != before
    }

    /// The helper said yes to putting this tab on `key`. Shown from now
    /// until the helper writes down anything newer.
    func note(workspace: String, tab: UInt32, key: String, at: Date = Date()) {
        notes[Self.id(workspace, tab)] = (key, at.timeIntervalSince1970 * 1000)
    }

    /// The account a tab runs on, or nil when it runs no AI.
    ///
    /// A tab running Claude that the file does not mention yet — started
    /// since it was written — is on the order, since that is what Claude
    /// started without an account of its own runs on; a Codex likewise on
    /// Codex's own login.
    func account(workspace: String, tab: UInt32, program: AIProgramKind) -> String? {
        guard program.runsAI else { return nil }
        let id = Self.id(workspace, tab)
        if let note = notes[id] { return note.key }
        if let entry = entries[id] { return entry.key }
        switch program {
        case .claude: return AIHelper.followOrder
        case .codex: return AIEngine.codex.key(AIAccounts.codexOwnSlot)
        default: return nil
        }
    }

    /// Only a recorded account of the program actually on screen may light
    /// the usage footer. A stale Claude record must not label a new Codex.
    func confirmedAccount(workspace: String, tab: UInt32, program: AIProgramKind) -> String? {
        guard program == .claude || program == .codex else { return nil }
        let id = Self.id(workspace, tab)
        guard let key = notes[id]?.key ?? entries[id]?.key else { return nil }
        let prefix = program == .codex ? "gpt:" : "claude:"
        return key.hasPrefix(prefix) ? key : nil
    }

    /// What the tabs show, for telling whether a read changed it.
    private var shown: [String: String] {
        var map = entries.mapValues(\.key)
        for (id, note) in notes { map[id] = note.key }
        return map
    }

    private static func id(_ workspace: String, _ tab: UInt32) -> String {
        "\(workspace)\u{1F}\(tab)"
    }

    /// The file's "ia" list and when it was written, or nil when it is not
    /// one to believe: another version of the format, or written for
    /// another daemon — its start, the birth of the socket, is compared to
    /// the millisecond, as the names are.
    nonisolated static func parse(
        _ data: Data, daemonStart: Date?
    ) -> (entries: [AITabAccount], written: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["versao"] as? NSNumber)?.intValue == 1,
              let start = daemonStart?.timeIntervalSince1970,
              let born = ((root["keepd"] as? [String: Any])?["inicio"] as? NSNumber)?.doubleValue,
              abs(born - start) < 0.001
        else { return nil }
        let written = (root["gravado_em_ms"] as? NSNumber)?.doubleValue ?? 0
        var entries: [AITabAccount] = []
        for item in (root["ia"] as? [[String: Any]]) ?? [] {
            guard let workspace = item["workspace"] as? String,
                  let tab = (item["aba"] as? NSNumber)?.uint32Value,
                  let key = item["conta"] as? String, AIHelper.isValidKey(key)
            else { continue }
            entries.append(AITabAccount(
                workspace: workspace, tab: tab,
                agent: item["agente"] as? String ?? "",
                key: key,
                link: item["vinculo"] as? String ?? ""))
        }
        return (entries, written)
    }
}

/// What a tab's AI menu offers, decided from the footer's lines — the order
/// of priority, and whether each account can take work now — the account the
/// tab is on, and what it is running. The same menu wherever it opens: the
/// strip's chevron and the sidebar's.
enum AIChoices {
    enum Mark: Equatable {
        case none
        /// The tab is on this.
        case on
        /// The tab is on the order, and the order is on this.
        case mixed
    }

    struct Row: Equatable {
        enum Kind: Equatable { case note, follow, separator, account }
        let kind: Kind
        let title: String
        /// What choosing it asks the helper for; nil for what is not a choice.
        let key: String?
        let mark: Mark
        let enabled: Bool
        let help: String?
        /// What the choice is called when it is spoken of afterwards — in a
        /// question about going on with it: "Claude · spare".
        var label: String = ""
    }

    static let followTitle = "Follow the order of priority"

    /// The menu, top to bottom.
    ///
    /// A tab running some other program is told so first, and nothing in it
    /// can be chosen: the helper will not type into a program it does not
    /// know.
    /// Then following the order, and one line per account in the order's
    /// order — the accounts that cannot take work now say so, and can still
    /// be chosen, since that is the person's call.
    static func rows(lines: [AccountUsage], current: String?, program: AIProgramKind) -> [Row] {
        var rows: [Row] = []
        let enabled = program.allowsChoice
        if case .other(let name) = program {
            rows.append(Row(
                kind: .note, title: "This tab is running \(name)", key: nil, mark: .none,
                enabled: false, help: nil))
        }
        let now = (lines.first(where: \.isAvailable) ?? lines.first).map { "Now: \($0.account.name)" }
        rows.append(Row(
            kind: .follow, title: followTitle, key: followOrderKey(lines),
            mark: current == AIHelper.followOrder ? .on : .none, enabled: enabled, help: now,
            label: "the order of priority"))
        guard !lines.isEmpty else { return rows }
        rows.append(Row(kind: .separator, title: "", key: nil, mark: .none, enabled: false, help: nil))
        for line in lines {
            let account = line.account
            var mark = Mark.none
            if let current, account.keys.contains(current) {
                mark = .on
            } else if current == AIHelper.followOrder, account.engine == .claude, account.isActive {
                mark = .mixed
            }
            rows.append(Row(
                kind: .account, title: title(line), key: account.engine.key(account.slot),
                mark: mark, enabled: enabled, help: nil, label: account.name))
        }
        return rows
    }

    /// "Claude · spare · two@example.com — at the limit": the service and
    /// the name the account is shown under, the address the service knows it
    /// by, and — when it cannot take work now — why.
    static func title(_ line: AccountUsage) -> String {
        var title = line.account.name
        if let email = line.account.email { title += " · \(email)" }
        if !line.isAvailable { title += " — \(line.account.warning ?? "at the limit")" }
        return title
    }

    /// What following the order means right now: the first account in it
    /// that can take work, or the first of all when none can. Claude is the
    /// order itself — the helper keeps the one login those tabs share on its
    /// first Claude that can — and a GPT account is that account.
    static func followOrderKey(_ lines: [AccountUsage]) -> String {
        guard let first = lines.first(where: \.isAvailable) ?? lines.first else {
            return AIHelper.followOrder
        }
        switch first.account.engine {
        case .claude: return AIHelper.followOrder
        case .codex: return first.account.engine.key(first.account.slot)
        }
    }

    /// What the sidebar writes after a tab's title: the program, or — for an
    /// AI kept on an account of its own — which one. "claude · spare";
    /// "codex · team" for a GPT account other than Codex's own login.
    static func programLabel(command: String, account: String?) -> String {
        guard let account, let colon = account.firstIndex(of: ":") else { return command }
        let service = account[..<colon]
        let alias = String(account[account.index(after: colon)...])
        switch service {
        case "claude" where alias != "ordem": return "claude · \(alias)"
        case "gpt" where alias != AIAccounts.codexOwnSlot: return "codex · \(alias)"
        default: return command
        }
    }
}
