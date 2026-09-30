import Foundation

/// Running one of the helpers that live outside the app — `keep-worktrees`,
/// `keep-ia` — and hearing what it printed.
///
/// Some things are known outside the app and should stay there: which
/// worktrees a conversation made, which login a tab runs on, how to put a tab
/// on another one. A helper answers in JSON on its standard output. What is
/// common to asking one is here: told which daemon the app is using, since a
/// test app runs against one of its own; read while it runs, so a long answer
/// cannot fill the pipe and stall the process writing it; and killed when it
/// outlives its time, since an answer held up by a hung helper would be a
/// button that does nothing.
///
/// Blocking; call it off the main thread.
enum ExternalHelper {
    /// What came back: how it exited, and everything it printed.
    struct Output {
        let status: Int32
        let data: Data
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// `name` is how the helper is called in what goes wrong: "keep-ia took
    /// longer than 40 s".
    static func run(
        _ helper: String, _ arguments: [String], within seconds: TimeInterval, name: String
    ) -> Result<Output, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["KEEP_SOCKET"] = Daemon.socketPath
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(Failure("\(name) did not start: \(error.localizedDescription)"))
        }
        // Read while it runs, so a large answer cannot fill the pipe and
        // stall the process that is writing it.
        var data = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        guard finished.wait(timeout: .now() + seconds) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return .failure(Failure("\(name) took longer than \(Int(seconds)) s"))
        }
        _ = reading.wait(timeout: .now() + 2)
        return .success(Output(status: process.terminationStatus, data: data))
    }
}

/// `keep-ia`: the order of priority among the AI accounts, signing in to
/// another one, and which account each tab runs on.
///
/// Every decision about an account or a credential is the helper's: it holds
/// the account vault and the tabs' processes. The app shows what the helper
/// wrote down and asks it for changes, in the helper's own words: always
/// `--json`, one object printed, `"versao": 1`; exit 0 for `ok: true`, 1 for
/// `ok: false` (the object printed all the same, with a `motivo` and a
/// `detalhe` to show as it is written), 2 for a question asked wrong. Its
/// commands, options, keys and reasons are its own, and are passed on as they
/// are. A value travels inside its option (`--ws=<name>`), so a workspace
/// whose name starts with a dash is still a workspace and not an option.
///
/// No helper, no feature: the footer's arrows and "+" and the tabs'
/// chevrons are only there when it is.
enum AIHelper {
    /// The key for Claude with no account of its own: whichever the order
    /// puts first, through the one login every such tab shares.
    static let followOrder = "claude:ordem"

    /// The deadlines below are the helper's contract; a test that waits them
    /// out takes them down to a fraction.
    nonisolated(unsafe) static var timeScale: Double = 1

    /// Where the helper is, or nil when there is none to ask.
    ///
    /// `KEEP_IA_BIN`, when it is set, is the only place looked at: a test
    /// that points it at nothing gets no helper, rather than falling through
    /// to the installed one. Otherwise `~/.local/bin/keep-ia` — but never for
    /// an app that reads a made-up home (`KEEP_AI_USAGE_HOME`, which every
    /// test build sets): the helper acts on the real home whatever the app
    /// reads, so an app showing another one has nothing to ask it. That rule
    /// stands on its own, so a test stays off the real accounts even with
    /// the first one broken. A GUI app inherits none of the shell's PATH, so
    /// the place is named.
    static var path: String? { path(environment: ProcessInfo.processInfo.environment) }

    static func path(environment: [String: String], installed: String? = nil) -> String? {
        if let named = environment["KEEP_IA_BIN"] { return isRunnable(named) ? named : nil }
        if environment["KEEP_AI_USAGE_HOME"] != nil { return nil }
        let installed = installed ?? installedPath(environment: environment)
        return isRunnable(installed) ? installed : nil
    }

    /// `~/.local/bin/keep-ia`, `~` being the `HOME` the app was started with,
    /// as the helper itself reads it — so a test run under a made-up `HOME`
    /// cannot reach the real one. `NSHomeDirectory()` alone would not do: it
    /// ignores `HOME`.
    static func installedPath(environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".local/bin/keep-ia")
    }

    /// An executable file. A directory passes `isExecutableFile` — it can be
    /// searched — and `/var/empty` is what the tests point this at.
    private static func isRunnable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return !path.isEmpty
            && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// A key the helper takes: `claude:<slot>`, `gpt:<name>`, or
    /// `claude:ordem`. Refused here before anything runs, so nothing that
    /// arrives from a file can become an option or a path on the way out.
    static func isValidKey(_ key: String) -> Bool {
        key.range(of: #"^(claude|gpt):[^\s/:]+$"#, options: .regularExpression) != nil
    }

    /// The two services a login can be opened for.
    enum Service: String {
        case claude
        case gpt
    }

    /// Why the helper did not do it: its own `motivo` (`ocupada`,
    /// `outro-programa`, …) when it answered, or the app's word for what kept
    /// it from answering (`invalid-key`, `no-helper`, `no-answer`,
    /// `unreadable`); and what to tell the person.
    ///
    /// `precisa-login` is a step rather than a failure: the account has no
    /// login of its own for a tab yet, and the helper has opened one in a
    /// tab — `aba_login`, in `ws_login` — that puts the tab on the account
    /// itself once it is through. The conversation has not been touched.
    struct Problem: Error, Equatable {
        let reason: String?
        let detail: String
        var login: (workspace: String?, tab: UInt32)? = nil

        static func == (a: Problem, b: Problem) -> Bool {
            a.reason == b.reason && a.detail == b.detail
                && a.login?.workspace == b.login?.workspace && a.login?.tab == b.login?.tab
        }
    }

    // MARK: - asking

    /// One place up or down the order. The answer is the order as the helper
    /// now has it.
    static func moveOrder(_ key: String, up: Bool) -> Result<[String], Problem> {
        guard isValidKey(key), key != followOrder else { return .failure(invalid(key)) }
        return ask(["ordem", "mover", key, up ? "cima" : "baixo", "--json"], within: 10 * timeScale)
            .map { ($0["ordem"] as? [String]) ?? [] }
    }

    /// A new tab in `workspace` where a login to another account is made;
    /// the answer is where the helper opened it.
    static func signIn(
        _ service: Service, workspace: String
    ) -> Result<(workspace: String, tab: UInt32), Problem> {
        ask(["entrar", service.rawValue, "--ws=\(workspace)", "--json"], within: 20 * timeScale)
            .flatMap { answer in
                guard let opened = answer["ws"] as? String,
                      let tab = (answer["aba"] as? NSNumber)?.uint32Value
                else {
                    return .failure(Problem(reason: "unreadable", detail: "keep-ia did not say which tab it opened."))
                }
                return .success((opened, tab))
            }
    }

    /// Put a tab on another AI or account. `interrupt` is the person's yes to
    /// stopping what the tab is doing, asked for after the helper said it was
    /// busy.
    static func switchAccount(
        workspace: String, tab: UInt32, to key: String, interrupt: Bool
    ) -> Result<String, Problem> {
        guard isValidKey(key) else { return .failure(invalid(key)) }
        var arguments = ["trocar", "--ws=\(workspace)", "--aba=\(tab)", "--para=\(key)"]
        if interrupt { arguments.append("--interromper") }
        arguments.append("--json")
        return ask(arguments, within: 40 * timeScale).map { ($0["feito"] as? String) ?? "" }
    }

    private static func invalid(_ key: String) -> Problem {
        Problem(reason: "invalid-key", detail: "“\(key)” is not an account keep-ia knows.")
    }

    /// One question, and its answer when the answer is yes.
    private static func ask(
        _ arguments: [String], within seconds: TimeInterval
    ) -> Result<[String: Any], Problem> {
        guard let helper = path else {
            return .failure(Problem(reason: "no-helper", detail: "keep-ia is not installed."))
        }
        Trace.log("ia", "keep-ia \(arguments.joined(separator: " "))")
        switch ExternalHelper.run(helper, arguments, within: seconds, name: "keep-ia") {
        case .failure(let why):
            return .failure(Problem(reason: "no-answer", detail: why.description))
        case .success(let output):
            guard let answer = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
                  (answer["versao"] as? NSNumber)?.intValue == 1
            else {
                return .failure(Problem(
                    reason: "unreadable",
                    detail: output.status == 2
                        ? "keep-ia did not understand the request."
                        : "Unreadable answer from keep-ia (it exited with \(output.status))."))
            }
            if output.status == 0, answer["ok"] as? Bool == true { return .success(answer) }
            let detail = (answer["detalhe"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "keep-ia exited with \(output.status)."
            let login = (answer["aba_login"] as? NSNumber).map {
                (workspace: answer["ws_login"] as? String, tab: $0.uint32Value)
            }
            return .failure(Problem(reason: answer["motivo"] as? String, detail: detail, login: login))
        }
    }
}
