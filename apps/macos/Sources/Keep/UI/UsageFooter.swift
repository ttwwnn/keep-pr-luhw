import AppKit
import SwiftUI

/// One account's place in the footer: who it is, and the last it said.
struct AccountUsage: Identifiable, Equatable, Codable {
    let account: AIAccountSummary
    /// The last reading that came back, kept through later failures: an old
    /// figure marked as old says more than a blank.
    var reading: UsageReading?
    var measuredAt: Date?
    /// Why the latest attempt brought nothing back, when it did not.
    var problem: String?

    var id: String { account.id }
}

/// Measures every signed-in account's usage, for every window's footer.
///
/// One for the app, not one per window: the answer is the same in all of
/// them, and each window asking on its own would multiply the requests by
/// the windows open. Five minutes between readings of an account — often
/// enough to see a window fill, rare enough to stay far from the services'
/// own limits — ticked every minute so a failure is retried sooner than a
/// success is repeated.
///
/// The work is the poller's shape: files and requests off the main thread,
/// one round at a time, and only the result handed back to the main actor.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var lines: [AccountUsage] = []
    /// A round somebody asked for is running.
    @Published private(set) var measuring = false

    private var timer: Timer?
    private var inFlight = false
    /// Per account, when it may be asked again after a failure, and whether
    /// even a click must wait — the service's own "too many requests" is the
    /// one pause a click does not get to skip.
    private var pauses: [String: (until: Date, firm: Bool)] = [:]
    private var lastClick = Date.distantPast
    /// A click that came while a round was running, owed a round of its own.
    private var clickPending = false

    nonisolated static let period: TimeInterval = 300
    nonisolated static let tick: TimeInterval = 60

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
        measure(clicked: false)
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measure(clicked: false) }
        }
        // In the common modes as well, so a drag or an open menu does not
        // hold the next reading back.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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

    private func measure(clicked: Bool) {
        guard !inFlight else { return }
        inFlight = true
        if clicked { measuring = true }
        let previous = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let pauses = self.pauses
        let home = self.home
        let environment = self.environment
        let session = self.session

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            let accounts = AIAccounts.discover(home: home)
            let versions = UsageEndpoint.installedVersions(home: home)
            var lines = accounts.map { account -> AccountUsage in
                var line = previous[account.summary.id]
                    ?? AccountUsage(account: account.summary, reading: nil, measuredAt: nil, problem: nil)
                line = AccountUsage(
                    account: account.summary, reading: line.reading,
                    measuredAt: line.measuredAt, problem: line.problem)
                return line
            }
            var newPauses: [String: (until: Date, firm: Bool)] = [:]
            let lock = NSLock()
            let group = DispatchGroup()
            // Started after the loop, not in it: the loop writes the same
            // arrays the answers write, and must be done before any answer
            // can arrive.
            var tasks: [URLSessionDataTask] = []

            for (index, account) in accounts.enumerated() {
                let id = account.summary.id
                let line = lines[index]
                if let pause = pauses[id], pause.until > now, !clicked || pause.firm {
                    newPauses[id] = pause
                    continue
                }
                let due = clicked
                    || line.measuredAt.map { now.timeIntervalSince($0) >= Self.period - 5 } ?? true
                    || line.problem != nil
                guard due else { continue }

                guard account.token != nil else {
                    lines[index].problem = "no saved credentials"
                    continue
                }
                if let expires = account.expiresAt, expires <= now.addingTimeInterval(60) {
                    // Not renewed from here — see AIUsage.swift. The tool that
                    // owns the login renews it, and the next tick reads it.
                    lines[index].problem = expires <= now
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
                        lines[index].reading = reading
                        lines[index].measuredAt = Date()
                        lines[index].problem = nil
                    case .failure(let problem, let pause):
                        lines[index].problem = problem
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
                if lines != self.lines { self.lines = lines }
                self.remember()
                if self.clickPending {
                    self.clickPending = false
                    self.measureNow()
                }
            }
        }
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
struct UsageFooter: View {
    @ObservedObject var monitor: UsageMonitor
    /// Quiet at rest, legible under the pointer (PRODUCT.md).
    @State private var hoverFold = false
    @State private var hoverMeasure = false
    /// Folded, it is one line per account. A convenience of this Mac's, so it
    /// lives in the app's defaults rather than in any window's record.
    @AppStorage("usageFooterFolded") private var folded = false

    var body: some View {
        if monitor.lines.isEmpty {
            // No login found: no footer, not an empty box.
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
            VStack(alignment: .leading, spacing: folded ? 3 : 8) {
                ForEach(monitor.lines) { line in
                    if folded {
                        compact(line)
                    } else {
                        block(line, now: now)
                    }
                }
            }
            .padding(.horizontal, 17)
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
        }
        .foregroundStyle(UsageInk.inkFaint)
    }

    private func title(_ line: AccountUsage) -> String {
        "\(line.account.engine.title) · \(line.account.alias)"
    }

    private func block(_ line: AccountUsage, now: Date) -> some View {
        let stale = line.problem != nil
            || line.measuredAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title(line))
                    .font(numbers)
                    .foregroundStyle(line.account.isActive ? UsageInk.ink : UsageInk.inkResting)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if line.account.isActive && line.account.engine == .claude {
                    Circle()
                        .fill(UsageInk.live)
                        .frame(width: 5, height: 5)
                        .help("The account the tabs are running on")
                }
                Spacer(minLength: 0)
            }
            .help(accountHelp(line, now: now))

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
    private func compact(_ line: AccountUsage) -> some View {
        let windows = Array((line.reading?.windows ?? []).prefix(2))
        let figures = windows.map { UsageText.percent($0.percent) }.joined(separator: " · ")
        // The address alone, cut at its end: its start is what tells the
        // logins apart, and the service is in the tooltip.
        let name = line.account.email ?? title(line)
        return HStack(spacing: 5) {
            Text(name)
                .font(numbers)
                .foregroundStyle(line.account.isActive ? UsageInk.ink : UsageInk.inkResting)
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
        if line.account.isActive && line.account.engine == .claude {
            lines.append("In use by the tabs")
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
    private static func ink(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(dark)
                : NSColor.black.withAlphaComponent(light)
        })
    }

    static let ink = ink(dark: 0.96, light: 0.92)
    static let inkResting = ink(dark: 0.60, light: 0.75)
    static let inkFaint = ink(dark: 0.38, light: 0.55)

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
