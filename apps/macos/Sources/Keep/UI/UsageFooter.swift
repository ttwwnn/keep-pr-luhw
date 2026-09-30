import AppKit
import SwiftUI

/// Measures every signed-in account's usage, for every window's footer.
///
/// One for the app, not one per window: the answer is the same in all of
/// them, and each window asking on its own would multiply the requests by
/// the windows open. Five minutes between readings of an account — often
/// enough to see a window fill, rare enough to stay far from the services'
/// own limits — ticked every minute so a failure is retried sooner than a
/// success is repeated.
///
/// Which accounts there are, and in what order, is watched apart from that:
/// a glance at the files every two seconds (`AIAccounts.signature`), which
/// reads nothing over the network, so that a login just made or an order
/// just changed by `keep-ia` shows at once — and only an account that is new
/// is measured on the spot.
///
/// The work is the poller's shape: files and requests off the main thread,
/// one round at a time, and only the result handed back to the main actor.
/// A round's readings are laid onto the lines as they are when it lands, by
/// account, never over them: a round takes seconds, and the list it started
/// from may have gained an account or been rearranged in the meantime.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var lines: [AccountUsage] = []
    /// A round somebody asked for is running.
    @Published private(set) var measuring = false
    /// Whether `keep-ia`, the helper that keeps the order and makes the
    /// logins, is here to be asked. Without it there is no order to change
    /// and no login to open, and the footer offers neither.
    @Published private(set) var helperAvailable = false
    /// What the footer has to say for a moment: a change the helper refused.
    @Published private(set) var notice: String?

    private var timer: Timer?
    private var glance: Timer?
    private var inFlight = false
    /// Per account, when it may be asked again after a failure, and whether
    /// even a click must wait — the service's own "too many requests" is the
    /// one pause a click does not get to skip.
    private var pauses: [String: (until: Date, firm: Bool)] = [:]
    private var lastClick = Date.distantPast
    /// A click that came while a round was running, owed a round of its own.
    private var clickPending = false
    /// Accounts found while a round was running, owed a reading as soon as
    /// it lands.
    private var owed: Set<String> = []

    /// The files the logins live in, as last read.
    private var signature: [String]?
    private var looking = false
    private var lookAgain = false
    /// The next look reads the files whether or not they seem to have changed.
    private var rereading = false

    /// Moves of the order asked of the helper and not yet answered.
    private var movesPending = 0
    /// The order being shown while the helper catches up with the arrows — by
    /// line, first to last — and until when it holds against the files.
    private var heldOrder: [String]?
    private var heldUntil = Date.distantPast
    /// One move at a time, in the order they were clicked: each is a step
    /// from wherever the one before left the order.
    private let orderQueue = DispatchQueue(label: "keep.usage.order", qos: .userInitiated)
    private var noticeTicket = 0

    nonisolated static let period: TimeInterval = 300
    nonisolated static let tick: TimeInterval = 60
    nonisolated static let glanceEvery: TimeInterval = 2
    /// How long an order shown ahead of the helper is held against what the
    /// files say, after the last arrow. The helper writes within a second;
    /// what this covers is a file read just before it did.
    nonisolated static let holdFor: TimeInterval = 10

    private let environment = ProcessInfo.processInfo.environment
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    /// Where the logins are read from. A test points this at a stand-in home
    /// so the real vault is never opened.
    private var home: URL {
        environment["KEEP_AI_USAGE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func start() {
        guard timer == nil else { return }
        restore()
        helperAvailable = AIHelper.path != nil
        // The accounts first, then a round over them: a round lays its
        // readings onto the lines there are, and there are none yet.
        look(thenMeasure: true)
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measure(clicked: false) }
        }
        // In the common modes as well, so a drag or an open menu does not
        // hold the next reading back.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let glance = Timer(timeInterval: Self.glanceEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.look() }
        }
        RunLoop.main.add(glance, forMode: .common)
        self.glance = glance
    }

    /// The footer's refresh button: every account, now — within reason.
    func measureNow() {
        guard Date().timeIntervalSince(lastClick) > 15 else { return }
        guard !inFlight else {
            // Not dropped: run as soon as the tick in flight lands.
            clickPending = true
            measuring = true
            return
        }
        lastClick = Date()
        measure(clicked: true)
    }

    // MARK: - which accounts, in what order

    /// A glance at the files the logins live in. Changed since the last one
    /// — a login added or renewed, the account the tabs run on switched,
    /// the order rewritten — the accounts are read again, and whatever is
    /// new among them measured now rather than at the next round.
    private func look(force: Bool = false, thenMeasure: Bool = false) {
        if force { rereading = true }
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        let home = self.home
        let known = rereading ? nil : signature
        rereading = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = AIAccounts.signature(home: home)
            let helper = AIHelper.path != nil
            let accounts = now == known ? nil : AIAccounts.discover(home: home).map(\.summary)
            DispatchQueue.main.async {
                guard let self else { return }
                self.looking = false
                if self.helperAvailable != helper { self.helperAvailable = helper }
                if let accounts {
                    self.signature = now
                    let fresh = self.adopt(accounts)
                    if !thenMeasure, !fresh.isEmpty {
                        Trace.log("usage", "found \(fresh.sorted().joined(separator: " ")); measuring now")
                        self.measure(clicked: false, only: fresh)
                    }
                }
                if thenMeasure { self.measure(clicked: false) }
                if self.lookAgain {
                    self.lookAgain = false
                    self.look()
                }
            }
        }
    }

    /// The accounts as the files have them now, each keeping what was last
    /// measured of it. The ones that were not there before, or have just
    /// been given a token, are handed back: they are worth asking about now.
    private func adopt(_ accounts: [AIAccountSummary]) -> Set<String> {
        let previous = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let next = holding(accounts.map { account in
            let line = previous[account.id]
            return AccountUsage(
                account: account, reading: line?.reading, measuredAt: line?.measuredAt,
                problem: line?.problem)
        })
        if next != lines {
            lines = next
            remember()
        }
        return Set(next.compactMap { line in
            guard let before = previous[line.id] else { return line.id }
            return before.account.hasToken != true && line.account.hasToken == true ? line.id : nil
        })
    }

    /// The order being held, laid over lines read from the files: an order
    /// changed by the arrows is shown before the helper has written it, and a
    /// file read in between must not put it back as it was.
    private func holding(_ next: [AccountUsage]) -> [AccountUsage] {
        guard let held = heldOrder else { return next }
        var rank: [String: Int] = [:]
        for (place, id) in held.enumerated() where rank[id] == nil { rank[id] = place }
        let placed = next.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return placed + next.filter { rank[$0.id] == nil }
    }

    /// One place up (`-1`) or down (`1`) the order of priority.
    ///
    /// Shown at once and asked of the helper behind it, one move at a time:
    /// the helper writes the order, and moves the tabs that follow it a few
    /// seconds after the last move. What it refuses is taken back — the order
    /// is read again as the helper has it — and said.
    func move(_ line: AccountUsage, by step: Int) {
        guard helperAvailable, step != 0,
              let at = lines.firstIndex(where: { $0.id == line.id }),
              lines.indices.contains(at + step)
        else { return }
        let key = lines[at].account.order
        let up = step < 0
        var next = lines
        next.insert(next.remove(at: at), at: at + step)
        lines = next
        heldOrder = next.map(\.id)
        heldUntil = Date().addingTimeInterval(Self.holdFor)
        movesPending += 1
        quiet()
        Trace.log("ia", "order: \(key) \(up ? "up" : "down"), shown now as "
            + next.map(\.account.order).joined(separator: " "))
        orderQueue.async { [weak self] in
            let answer = AIHelper.moveOrder(key, up: up)
            DispatchQueue.main.async { self?.moved(key, answer) }
        }
        releaseLater()
    }

    private func moved(_ key: String, _ answer: Result<[String], AIHelper.Problem>) {
        movesPending -= 1
        switch answer {
        case .success(let order):
            Trace.log("ia", "order: the helper has \(order.joined(separator: " "))")
        case .failure(let problem):
            Trace.log("ia", "order: \(key) refused (\(problem.reason ?? "?")): \(problem.detail)")
            // Taken back by reading the order as the helper has it — which also
            // keeps whatever an earlier move did get through.
            heldOrder = nil
            say("Could not change the order: \(problem.detail)")
            look(force: true)
        }
        if movesPending == 0 { releaseLater() }
    }

    /// Stop holding the order once the last move is answered and the hold
    /// has run out, and read what the files say: the helper's word is the last.
    private func releaseLater() {
        let until = heldUntil
        let wait = max(0, until.timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.heldUntil == until, self.movesPending == 0, self.heldOrder != nil
            else { return }
            self.heldOrder = nil
            self.look(force: true)
        }
    }

    /// Something said in the footer for a few seconds.
    private func say(_ text: String) {
        noticeTicket += 1
        let ticket = noticeTicket
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.noticeTicket == ticket else { return }
            self.notice = nil
        }
    }

    private func quiet() {
        noticeTicket += 1
        if notice != nil { notice = nil }
    }

    // MARK: - how much each has spent

    /// One round of readings: every account due, or `only` these, now.
    private func measure(clicked: Bool, only: Set<String>? = nil) {
        guard !inFlight else {
            if let only { owed.formUnion(only) }
            return
        }
        inFlight = true
        if clicked { measuring = true }
        let previous = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pauses = self.pauses
        let home = self.home
        let environment = self.environment
        let session = self.session

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            // Read again for the tokens, which live nowhere else: nothing the
            // view holds carries one.
            let accounts = AIAccounts.discover(home: home)
            let versions = UsageEndpoint.installedVersions(home: home)
            // What each line will say when the round is over, starting from
            // what it says now.
            var results: [String: Finding] = [:]
            for account in accounts {
                let line = previous[account.summary.id]
                results[account.summary.id] = Finding(
                    reading: line?.reading, measuredAt: line?.measuredAt, problem: line?.problem)
            }
            var newPauses = pauses.filter { $0.value.until > now }
            let lock = NSLock()
            let group = DispatchGroup()
            // Started after the loop, not in it: the loop writes the same
            // tables the answers write, and must be done before any answer
            // can arrive.
            var tasks: [URLSessionDataTask] = []

            for account in accounts {
                let id = account.summary.id
                guard only?.contains(id) ?? true, let line = results[id] else { continue }
                if let pause = pauses[id], pause.until > now, !clicked || pause.firm { continue }
                let due = clicked || only != nil
                    || line.measuredAt.map { now.timeIntervalSince($0) >= Self.period - 5 } ?? true
                    || line.problem != nil
                guard due else { continue }
                newPauses[id] = nil

                guard account.token != nil else {
                    results[id]?.problem = "no saved credentials"
                    continue
                }
                if let expires = account.expiresAt, expires <= now.addingTimeInterval(60) {
                    // Not renewed from here — see AIUsage.swift. The tool that
                    // owns the login renews it, and the next tick reads it.
                    results[id]?.problem = expires <= now
                        ? "access expired \(UsageText.moment(expires, now: now)); renewed on next use"
                        : "access expires now; measuring in the next minute"
                    continue
                }
                guard let request = UsageEndpoint.request(
                    for: account, environment: environment, clientVersions: versions)
                else { continue }

                group.enter()
                let started = Date()
                tasks.append(session.dataTask(with: request) { data, response, error in
                    defer { group.leave() }
                    let status = (response as? HTTPURLResponse)?.statusCode
                    let outcome = Self.outcome(
                        engine: account.engine, data: data, status: status,
                        retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
                        failed: error != nil, now: Date())
                    Trace.log("usage", "\(id) status=\(status.map(String.init) ?? "none") "
                        + "in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                    lock.lock()
                    defer { lock.unlock() }
                    switch outcome {
                    case .reading(let reading):
                        results[id]?.reading = reading
                        results[id]?.measuredAt = Date()
                        results[id]?.problem = nil
                    case .failure(let problem, let pause):
                        results[id]?.problem = problem
                        if let pause { newPauses[id] = pause }
                    }
                })
            }
            tasks.forEach { $0.resume() }
            group.wait()

            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.measuring = false
                self.pauses = newPauses
                self.settle(results)
                self.remember()
                if !self.owed.isEmpty {
                    let owed = self.owed
                    self.owed = []
                    self.measure(clicked: false, only: owed)
                } else if self.clickPending {
                    self.clickPending = false
                    self.measureNow()
                }
            }
        }
    }

    /// What a round found out about one account.
    private struct Finding {
        var reading: UsageReading?
        var measuredAt: Date?
        var problem: String?
    }

    /// A round's findings, onto the lines as they are now, account by
    /// account. The lines themselves — which there are, and their order —
    /// are the files' and the arrows' to decide, not a round's.
    private func settle(_ results: [String: Finding]) {
        var next = lines
        for index in next.indices {
            guard let result = results[next[index].id] else { continue }
            next[index].reading = result.reading
            next[index].measuredAt = result.measuredAt
            next[index].problem = result.problem
        }
        if next != lines { lines = next }
    }

    // MARK: - across relaunches

    /// Readings and the service's "wait until" kept in the app's defaults —
    /// no token, only figures — so a relaunch shows the last figures at once
    /// and keeps to the five minutes and to a 429's Retry-After, instead of
    /// asking every service the moment the app opens. Not when a test points
    /// the monitor at a home of its own.
    private var persists: Bool { environment["KEEP_AI_USAGE_HOME"] == nil }
    private static let linesKey = "usageFooterLines"
    private static let pausesKey = "usageFooterWaitUntil"

    private func restore() {
        guard persists else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.linesKey),
           let saved = try? JSONDecoder().decode([AccountUsage].self, from: data) {
            lines = saved
        }
        let now = Date()
        for (id, until) in (defaults.dictionary(forKey: Self.pausesKey) as? [String: Double]) ?? [:] {
            let date = Date(timeIntervalSince1970: until)
            if date > now { pauses[id] = (date, true) }
        }
    }

    private func remember() {
        guard persists else { return }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(lines) { defaults.set(data, forKey: Self.linesKey) }
        let firm = pauses.filter { $0.value.firm }.mapValues { $0.until.timeIntervalSince1970 }
        defaults.set(firm, forKey: Self.pausesKey)
    }

    private enum Outcome {
        case reading(UsageReading)
        case failure(String, (until: Date, firm: Bool)?)
    }

    /// What one answer means for the footer, and how long before asking
    /// again if it was no answer.
    nonisolated private static func outcome(
        engine: AIEngine, data: Data?, status: Int?, retryAfter: String?, failed: Bool, now: Date
    ) -> Outcome {
        guard let status, !failed else {
            return .failure("no network; trying again in 1 min", (now.addingTimeInterval(60), false))
        }
        switch status {
        case 200:
            let reading = data.flatMap { engine == .claude ? UsageParse.claude($0) : UsageParse.codex($0) }
            guard let reading else {
                return .failure("no readable limits in the answer", (now.addingTimeInterval(Self.period), false))
            }
            return .reading(reading)
        case 401, 403:
            return .failure(
                "the service refused access (HTTP \(status)); renewed on next use",
                (now.addingTimeInterval(Self.period), false))
        case 429:
            let wait = retryAfter.flatMap(Double.init).map { max(60, $0) } ?? 600
            let until = now.addingTimeInterval(wait)
            return .failure(
                "too many requests (HTTP 429); trying again \(UsageText.moment(until, now: now))",
                (until, true))
        default:
            return .failure("no reading (HTTP \(status))", (now.addingTimeInterval(60), false))
        }
    }
}

// MARK: - the footer

/// The usage footer at the bottom of the sidebar: every signed-in account,
/// its windows as bars, and when each starts over.
///
/// Set apart by a rule and pinned under the list (DESIGN.md: "the footer is
/// set apart by a rule"), quiet until something is near its limit: the bars
/// are the ink of resting text, and only a window past 75% takes a colour —
/// amber, then red from 90. The figure is always written beside the bar, so
/// the colour is never the only thing saying it.
///
/// The accounts are listed in the order of priority, and — when `keep-ia`
/// is here — each with its place in it, arrows to move one up or down, and
/// a "+" in the heading to sign in to another.
struct UsageFooter: View {
    @ObservedObject var monitor: UsageMonitor
    /// This window's channel to the session: a login opened from here opens
    /// in the workspace this window is in.
    let dispatch: (Intent) -> Void
    var selectedAccount: String? = nil
    /// Quiet at rest, legible under the pointer (PRODUCT.md).
    @State private var hoverFold = false
    @State private var hoverMeasure = false
    @State private var hoverArrow: String?
    /// Folded, it is one line per account. A convenience of this Mac's, so it
    /// lives in the app's defaults rather than in any window's record.
    @AppStorage("usageFooterFolded") private var folded = false

    var body: some View {
        if monitor.lines.isEmpty && !monitor.helperAvailable {
            // No login found and nothing to sign in with: no footer, not an
            // empty box.
            Color.clear.frame(height: 0)
        } else {
            // Re-read the clock every half minute, so "4h10" keeps counting
            // down between readings without anybody publishing anything.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                footer(now: context.date)
            }
        }
    }

    private var numbers: Font { Font(GhosttyApp.shared.terminalFont(size: 11)) }

    private func footer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(UsageInk.wash(0.08))
                .frame(height: 1)
            header
                .padding(.horizontal, 17)
                .padding(.top, 7)
                .padding(.bottom, folded ? 4 : 5)
            if let notice = monitor.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(UsageInk.attention)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: folded ? 3 : 8) {
                ForEach(Array(monitor.lines.enumerated()), id: \.element.id) { index, line in
                    if folded {
                        compact(line, at: index)
                    } else {
                        block(line, at: index, now: now)
                    }
                }
            }
            .padding(.horizontal, 17)
            // An account that moves in the order is seen to move: the
            // arrows' answer, in the footer's own time.
            .animation(.easeOut(duration: 0.18), value: monitor.lines.map(\.id))
        }
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.15), value: folded)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                folded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    Text("AI usage")
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoverFold ? UsageInk.inkResting : UsageInk.inkFaint)
            .onHover { hoverFold = $0 }
            .accessibilityLabel("AI usage")
            .help(folded ? "Show each account's windows" : "One line per account")
            Spacer(minLength: 4)
            if monitor.helperAvailable {
                // Signing in is a menu of two, and the login itself is the
                // helper's: it opens in a tab of this window's workspace.
                MenuGlyph(
                    symbol: "plus", pointSize: 9, weight: .semibold,
                    label: "Sign in to another account", identifier: "usage-signin",
                    help: "Sign in to another account",
                    resting: UsageInk.faintColor, lit: UsageInk.restingColor,
                    menu: { AccountMenu.signIn { engine in dispatch(.signIn(engine)) } })
                    .frame(width: 16, height: 14)
            }
            Button {
                monitor.measureNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoverMeasure ? UsageInk.inkResting : UsageInk.inkFaint)
            .onHover { hoverMeasure = $0 }
            .opacity(monitor.measuring ? 0.35 : 1)
            .help("Measure now")
            .accessibilityLabel("Measure now")
        }
        .foregroundStyle(UsageInk.inkFaint)
    }

    /// "Claude · main": the service and the name the account is shown under.
    private func title(_ line: AccountUsage) -> String { line.account.name }

    /// "2 · Claude · spare": the same, after its place in the order, which
    /// is what the arrows beside it change. The place is written only when
    /// `keep-ia` is here to keep the order: without it the footer is as it
    /// always was.
    private func heading(_ text: String, _ line: AccountUsage, at index: Int) -> Text {
        let name = Text(text).foregroundColor(line.account.isUsed(by: selectedAccount) ? UsageInk.ink : UsageInk.inkResting)
        guard monitor.helperAvailable else { return name }
        return Text("\(index + 1) · ").foregroundColor(UsageInk.inkFaint) + name
    }

    private func block(_ line: AccountUsage, at index: Int, now: Date) -> some View {
        let stale = line.problem != nil
            || line.measuredAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    heading(title(line), line, at: index)
                        .font(numbers)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if line.account.isUsed(by: selectedAccount) {
                        Circle()
                            .fill(UsageInk.live)
                            .frame(width: 5, height: 5)
                            .help("Account used by this tab")
                            .accessibilityLabel("Account used by this tab")
                            .accessibilityIdentifier("usage-active-\(line.account.order)")
                    }
                    Spacer(minLength: 0)
                }
                .help(accountHelp(line, now: now))
                arrows(line, at: index)
            }

            // Which login this is, written out: the slot's name says which
            // one the vault means, the address says which one the service does.
            if let email = line.account.email {
                Text(email)
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsageInk.inkResting)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(accountHelp(line, now: now))
            }

            if let reading = line.reading {
                ForEach(Array(reading.windows.enumerated()), id: \.offset) { _, window in
                    bar(window, of: line, now: now)
                }
                .opacity(stale ? 0.55 : 1)
            }

            if let note = note(line, now: now) {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(line.reading?.limitReached == true ? UsageInk.critical : UsageInk.inkFaint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ▲ and ▼: one place up or down the order of priority. The first
    /// has nowhere up to go and the last nowhere down, and each keeps the
    /// other's place, so the arrows stand in one column.
    ///
    /// Beside the line rather than part of it: the folded line is one element
    /// to the accessibility tree, and anything inside it could not be pressed.
    @ViewBuilder
    private func arrows(_ line: AccountUsage, at index: Int) -> some View {
        if monitor.helperAvailable {
            HStack(spacing: 1) {
                arrow(line, up: true, shown: index > 0)
                arrow(line, up: false, shown: index < monitor.lines.count - 1)
            }
        }
    }

    private func arrow(_ line: AccountUsage, up: Bool, shown: Bool) -> some View {
        let key = "\(up ? "up" : "down") \(line.id)"
        return Button {
            monitor.move(line, by: up ? -1 : 1)
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hoverArrow == key ? UsageInk.inkResting : UsageInk.inkFaint)
        .onHover { inside in
            hoverArrow = inside ? key : (hoverArrow == key ? nil : hoverArrow)
        }
        .help(up ? "Move up in the order of priority" : "Move down in the order of priority")
        .accessibilityLabel("Move \(title(line)) \(up ? "up" : "down")")
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }

    private func bar(_ window: UsageWindow, of line: AccountUsage, now: Date) -> some View {
        let level = UsageText.level(window.percent)
        let until = UsageText.until(window.resetsAt, now: now)
        return HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10))
                .foregroundStyle(UsageInk.inkResting)
                .lineLimit(1)
                // The middle: an additional limit's label ends in the window
                // ("… 5h", "… 7d") that tells two of them apart.
                .truncationMode(.middle)
                .frame(width: 34, alignment: .leading)
            GeometryReader { space in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageInk.wash(0.12))
                    Capsule()
                        .fill(UsageInk.fill(level))
                        .frame(width: max(2, space.size.width * min(window.percent, 100) / 100))
                }
            }
            .frame(height: 4)
            Text(UsageText.percent(window.percent))
                .font(numbers)
                .monospacedDigit()
                .foregroundStyle(level == .normal ? UsageInk.inkResting : UsageInk.fill(level))
                .frame(width: 34, alignment: .trailing)
            Text(until ?? "")
                .font(.system(size: 10))
                .foregroundStyle(UsageInk.inkFaint)
                .lineLimit(1)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 13)
        .help(barHelp(window, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title(line)) \(window.label) \(UsageText.percent(window.percent))"
                + (until.map { " resets in \($0)" } ?? ""))
    }

    /// Folded: the account — by its address, which is what tells two logins
    /// of one service apart — and the figures of its first two windows, each
    /// in its own colour: one amber figure must not paint its calm neighbour.
    private func compact(_ line: AccountUsage, at index: Int) -> some View {
        let windows = Array((line.reading?.windows ?? []).prefix(2))
        let figures = windows.map { UsageText.percent($0.percent) }.joined(separator: " · ")
        // The address alone, cut at its end: its start is what tells the
        // logins apart, and the service is in the tooltip.
        let name = line.account.email ?? title(line)
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                heading(name, line, at: index)
                    .font(numbers)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                compactFigures(windows)
                    .font(numbers)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .frame(height: 14)
            .help(([title(line)] + windows.map { "\($0.title): \(UsageText.percent($0.percent))" })
                .joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(line.account.engine.title) \(name) \(figures)")
            arrows(line, at: index)
        }
    }

    private func compactFigures(_ windows: [UsageWindow]) -> Text {
        guard !windows.isEmpty else { return Text("—").foregroundColor(UsageInk.inkFaint) }
        var text = Text("")
        for (index, window) in windows.enumerated() {
            if index > 0 { text = text + Text(" · ").foregroundColor(UsageInk.inkFaint) }
            let level = UsageText.level(window.percent)
            text = text + Text(UsageText.percent(window.percent))
                .foregroundColor(level == .normal ? UsageInk.inkResting : UsageInk.fill(level))
        }
        return text
    }

    private func note(_ line: AccountUsage, now: Date) -> String? {
        var parts: [String] = []
        if line.reading?.limitReached == true { parts.append("at the limit") }
        if let warning = line.account.warning { parts.append(warning) }
        if let problem = line.problem {
            parts.append(problem)
        } else if line.reading == nil {
            parts.append("measuring…")
        }
        if let at = line.measuredAt, now.timeIntervalSince(at) > 15 * 60 {
            parts.append("measured \(UsageText.ago(at, now: now))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func accountHelp(_ line: AccountUsage, now: Date) -> String {
        var lines: [String] = []
        if let email = line.account.email { lines.append(email) }
        if let plan = line.account.plan { lines.append("\(plan) plan") }
        if line.account.aliases.count > 1 {
            lines.append("In the vault as: " + line.account.aliases.joined(separator: ", "))
        }
        if line.account.isUsed(by: selectedAccount) {
            lines.append("Account used by this tab")
        }
        if let at = line.measuredAt { lines.append("Measured \(UsageText.ago(at, now: now))") }
        return lines.joined(separator: "\n")
    }

    private func barHelp(_ window: UsageWindow, now: Date) -> String {
        var text = "\(window.title): \(UsageText.percent(window.percent)) used"
        if let resets = window.resetsAt {
            text += "\nResets \(UsageText.moment(resets, now: now))"
        }
        return text
    }
}

/// The footer's inks: the sidebar's own (`Palette` in WorkspaceSidebar.swift,
/// private to that file), and the two warning hues it lacks. Same values, so
/// the footer's text sits with the list's.
private enum UsageInk {
    private static func inkColor(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(dark)
                : NSColor.black.withAlphaComponent(light)
        }
    }

    static let ink = Color(nsColor: inkColor(dark: 0.96, light: 0.92))
    static let inkResting = Color(nsColor: restingColor)
    static let inkFaint = Color(nsColor: faintColor)
    /// The same two, for the controls drawn by AppKit.
    static let restingColor = inkColor(dark: 0.60, light: 0.75)
    static let faintColor = inkColor(dark: 0.38, light: 0.55)

    static func wash(_ alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(alpha)
                : NSColor.black.withAlphaComponent(alpha)
        })
    }

    /// A state hue a step darker on a light ground, as the sidebar's are.
    private static func state(_ lightness: Double, _ chroma: Double, _ hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return oklch(dark ? lightness : lightness - 0.22, chroma, hue)
        })
    }

    /// The sidebar's "attached" green: the account the tabs are on.
    static let live = state(0.76, 0.14, 150)
    /// The sidebar's "busy" amber.
    static let attention = state(0.82, 0.15, 85)
    static let critical = state(0.70, 0.19, 27)

    static func fill(_ level: UsageText.Level) -> Color {
        switch level {
        case .normal: return inkResting
        case .attention: return attention
        case .critical: return critical
        }
    }

    /// OKLCH to sRGB, the same conversion the sidebar's palette uses.
    private static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> NSColor {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ channel: Double) -> Double {
            let value = max(0, min(1, channel))
            return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return NSColor(
            srgbRed: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            alpha: 1)
    }
}
