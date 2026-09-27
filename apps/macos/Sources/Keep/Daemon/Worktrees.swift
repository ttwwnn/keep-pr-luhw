import Foundation

/// The git worktrees a tab's conversation made, which go to the Trash when
/// the tab is closed.
///
/// A Claude Code session spins up worktrees for its work and leaves them
/// behind: closing its tab ended the work, and the folders — each a full
/// checkout, vendor and all — stayed until somebody went through the projects
/// folder by hand deciding which were whose. The rule of that sweep is the
/// rule here: a worktree belongs to the tab whose conversation created it,
/// an open tab is in use, and when in doubt it is not the tab's.
///
/// Which worktrees those are is not something this app can see. The process
/// in the tab sits in the directory it was started in while its work happens
/// elsewhere; what connects a tab to its conversation, and a conversation to
/// the worktrees it made, is the conversation's own record and the moment
/// each worktree was born. A helper outside the app works that out —
/// `keep-worktrees`, an executable in ~/.local/bin — and answers in JSON. Its
/// commands, keys and reasons are its own, and are passed on as they are.
/// Without the helper nothing here happens: the question before closing
/// stays as it was.
///
/// The app keeps the two steps that must happen inside a long-lived process
/// or with the person watching: saying it in the question before anything
/// ends, and the move itself, `FileManager.trashItem` — Finder's "Put Back"
/// is written down asynchronously by the process that trashes, and a helper
/// that exited straight after would lose it.
///
/// Blocking throughout; call it off the main thread.
enum Worktrees {
    /// What to ask about: a daemon workspace and the daemon tabs in it that
    /// are being closed — a tab's root and its panes, or a lone pane.
    struct Target: Equatable {
        let workspace: String
        let tabs: [UInt32]

        var argument: String {
            "\(workspace):" + tabs.map(String.init).joined(separator: ",")
        }
    }

    /// The helper's answer to `listar`.
    struct Listing: Decodable {
        struct Tab: Decodable {
            let alvo: String
            let pids: [Int32]?
        }

        struct Running: Decodable {
            let pid: Int32
            let nome: String?
        }

        struct Item: Decodable {
            let caminho: String
            let ramo: String?
            let head: String?
            let alteracoes: Int?
            let commits_so_aqui: Int?
            let processos: [Running]?
            /// When the worktree was born, so `preparar` can refuse a
            /// different one made at the same path while the question was up.
            let nasceu_ns: Int64?
        }

        struct Kept: Decodable {
            let caminho: String
            let motivo: String
        }

        let versao: Int
        let abas: [Tab]?
        let lixeira: [Item]?
        let mantidas: [Kept]?
        let avisos: [String]?

        /// The processes that end with the tabs, to be waited for before
        /// anything moves: a folder still being written to follows nobody to
        /// the Trash.
        var pids: [Int32] { (abas ?? []).flatMap { $0.pids ?? [] } }
    }

    enum Answer {
        /// No helper on this machine: nothing to say, nothing to move.
        case off
        case listing(Listing)
        /// The helper is there and did not answer. Said in the question, and
        /// nothing moves: a guess is not consent.
        case failed(String)
    }

    /// `KEEP_WORKTREES_BIN` for a test, else the installed one. A GUI app
    /// inherits none of the shell's PATH, so the place is named.
    static var helper: String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["KEEP_WORKTREES_BIN"],
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/keep-worktrees"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - asking

    /// The worktrees that go with these tabs.
    ///
    /// Asked before the question, because after the tab closes the
    /// conversation in it is gone and so is the only live link between the
    /// tab and what it made. `deadline` is the helper's; the app allows it a
    /// moment more to be heard.
    static func list(_ targets: [Target], deadline: TimeInterval = 3) -> Answer {
        guard let helper else { return .off }
        guard !targets.isEmpty else { return .listing(Listing(versao: 1, abas: [], lixeira: [], mantidas: [], avisos: [])) }
        let arguments = ["listar", "--prazo", String(format: "%.1f", deadline)] + targets.map(\.argument)
        switch run(helper, arguments, within: deadline + 1.5) {
        case .failure(let why):
            return .failed(why.description)
        case .success(let data):
            guard let listing = try? JSONDecoder().decode(Listing.self, from: data), listing.versao == 1
            else { return .failed("unreadable answer from keep-worktrees") }
            return .listing(listing)
        }
    }

    /// What the question adds: which folders go, which stay and why, or that
    /// nothing could be checked. Empty when there is nothing to say.
    ///
    /// `subject` is what is being closed, as the sentence says it: "this
    /// tab", "this pane", "this workspace".
    static func note(for answer: Answer, about subject: String = "this tab") -> String {
        switch answer {
        case .off:
            return ""
        case .failed(let why):
            return "\n\nThe worktrees from \(subject) could not be checked (\(why)); none will be moved."
        case .listing(let listing):
            var parts: [String] = []
            let going = listing.lixeira ?? []
            if !going.isEmpty {
                var text = going.count == 1
                    ? "The worktree from \(subject) goes to the Trash:"
                    : "The \(going.count) worktrees from \(subject) go to the Trash:"
                for item in going { text += "\n• " + describe(item) }
                // Put Back brings the files, not the worktree: its entry in
                // the repository is dropped so the branch is free again.
                text += "\nPut Back in the Trash brings the files back, no longer known to git; "
                    + "the branch stays in the repository, and the commits and changes are kept under refs/keep-lixeira."
                parts.append(text)
            }
            let kept = listing.mantidas ?? []
            if !kept.isEmpty {
                var text = kept.count == 1 ? "Stays where it is:" : "Stay where they are:"
                for item in kept { text += "\n• \(tilde(item.caminho)) — \(item.motivo)" }
                parts.append(text)
            }
            parts += listing.avisos ?? []
            return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n\n")
        }
    }

    /// One folder's line: where, and what in it is not anywhere else.
    static func describe(_ item: Listing.Item) -> String {
        var facts: [String] = []
        if let branch = item.ramo, !branch.isEmpty {
            facts.append("branch \(branch)")
        } else if let head = item.head, !head.isEmpty {
            facts.append("no branch, at \(head)")
        }
        if let changed = item.alteracoes, changed > 0 {
            facts.append(changed == 1 ? "1 file changed" : "\(changed) files changed")
        }
        if let only = item.commits_so_aqui, only > 0 {
            facts.append(only == 1 ? "1 commit only there" : "\(only) commits only there")
        }
        if let running = item.processos, !running.isEmpty {
            let names = running.map { $0.nome ?? "pid \($0.pid)" }
            facts.append("still running inside: " + names.joined(separator: ", "))
        }
        return tilde(item.caminho) + (facts.isEmpty ? "" : " (" + facts.joined(separator: "; ") + ")")
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - moving

    /// Move the listed folders to the Trash once the tabs' processes are gone.
    ///
    /// Only what the question showed: consent was given for that list, and a
    /// worktree born since is not in it. Each folder is prepared by the
    /// helper first — its HEAD, and any change not yet committed, saved in
    /// `refs/keep-lixeira` so no commit depends on the folder surviving the
    /// Trash — then moved here, then its registration in the repository
    /// dropped by the helper, so its branch and its name are free again. A
    /// folder something still runs in is retried for a minute, the time a
    /// test runner the conversation left behind takes to notice; after that
    /// it stays, and says so.
    ///
    /// Returns what did not go, one line each; empty when everything did.
    static func trash(_ listing: Listing) -> [String] {
        guard let helper else { return [] }
        let going = listing.lixeira ?? []
        guard !going.isEmpty else { return [] }
        // The tabs' own processes gone, or nothing moves: a conversation
        // still running is still using its worktrees, whatever the close
        // reported. Twenty seconds covers Claude Code's own grace on a hang-up.
        let running = waitForExit(listing.pids, upTo: 20)
        guard running.isEmpty else {
            let pids = running.map(String.init).joined(separator: ", ")
            return going.map {
                "\(tilde($0.caminho)): the tab's conversation is still running (pid \(pids)); nothing was moved"
            }
        }

        var problems: [String] = []
        for item in going {
            let place = tilde(item.caminho)
            var ready = false
            var reason = "no answer from keep-worktrees"
            let giveUp = Date().addingTimeInterval(60)
            let identity = item.nasceu_ns.map { ["--nasceu", String($0)] } ?? []
            while true {
                switch run(helper, ["preparar", item.caminho] + identity, within: 30) {
                case .failure(let why):
                    reason = why.description
                case .success(let data):
                    let answer = object(data)
                    if answer["ok"] as? Bool == true {
                        ready = true
                    } else {
                        reason = answer["motivo"] as? String ?? "refused by keep-worktrees"
                        // Only something still running is worth waiting out.
                        let running = (answer["processos"] as? [Any]) ?? []
                        if !running.isEmpty, Date() < giveUp {
                            Thread.sleep(forTimeInterval: 3)
                            continue
                        }
                    }
                }
                break
            }
            guard ready else {
                problems.append("\(place): \(reason)")
                continue
            }

            var moved: NSURL?
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: item.caminho), resultingItemURL: &moved)
            } catch {
                problems.append("\(place): \(error.localizedDescription)")
                continue
            }
            let destination = (moved as URL?)?.path ?? ""
            Trace.log("worktree", "trashed \(place)")
            switch run(helper, ["concluir", item.caminho, destination], within: 30) {
            case .failure(let why):
                problems.append("\(place) went to the Trash, but git still lists it: \(why)")
            case .success(let data):
                let answer = object(data)
                if answer["ok"] as? Bool != true {
                    let why = answer["motivo"] as? String ?? "refused"
                    problems.append("\(place) went to the Trash, but git still lists it: \(why)")
                }
            }
        }
        return problems
    }

    /// Until every one of these is gone, or the time is up; the ones still
    /// running then.
    ///
    /// A zombie counts as gone: it runs nothing, and a shell killed under
    /// its parent can stay one until the parent reaps it — which `kill(pid,
    /// 0)` alone would read as alive for ever.
    static func waitForExit(_ pids: [Int32], upTo seconds: TimeInterval) -> [Int32] {
        let until = Date().addingTimeInterval(seconds)
        func alive(_ pid: Int32) -> Bool {
            guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
            return Int32(info.kp_proc.p_stat) != SZOMB
        }
        while pids.contains(where: alive), Date() < until {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return pids.filter(alive)
    }

    // MARK: - running the helper

    private static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Run the helper and hand back what it printed, or why there is nothing.
    ///
    /// Told which daemon the app is using, since a test app runs against one
    /// of its own. Killed when it outlives `within`: a question held open by
    /// a hung helper would be a close button that does nothing.
    static func run(_ helper: String, _ arguments: [String], within seconds: TimeInterval)
        -> Result<Data, RunFailure>
    {
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
            return .failure(RunFailure("keep-worktrees did not start: \(error.localizedDescription)"))
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
            return .failure(RunFailure("keep-worktrees took longer than \(Int(seconds)) s"))
        }
        _ = reading.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else {
            return .failure(RunFailure("keep-worktrees exited with \(process.terminationStatus)"))
        }
        return .success(data)
    }

    struct RunFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

