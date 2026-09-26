import Foundation

/// Polls the daemon every two seconds and hands the listing to the session.
///
/// The socket work happens off the main thread: `Daemon.list()` is blocking
/// I/O, and a daemon busy in its parser must never become a UI hitch. Only
/// the reconciliation runs on the main actor.
@MainActor
final class DaemonPoller {
    private let session: Session
    private var timer: Timer?
    private var inFlight = false

    init(session: Session) {
        self.session = session
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        // Which listing this is: one an intent has overtaken is dropped.
        let generation = session.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listing = try? Daemon.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if let listing { self.session.reconcile(listing, asOf: generation) }
            }
        }
    }
}

/// Reads Claude Code's permission mode off the screens of the tabs running it.
///
/// Claude Code tells nobody when shift-tab changes its mode — no hook fires
/// and no sequence reaches the terminal — but it writes the mode under its
/// prompt the moment it changes. The daemon holds every tab's screen, hidden
/// tabs included, so asking it once a second is the whole mechanism.
///
/// A second, not two: the mode is something you just changed and are looking
/// for, and the other poll's two seconds are long enough to notice. Only the
/// tabs that look like Claude Code are asked, a few small reads.
@MainActor
final class ClaudeModeWatcher {
    private let session: Session
    private var timer: Timer?
    private var inFlight = false
    /// A bound, not a target: past this many tabs the rest wait a turn.
    private static let perTick = 24

    init(session: Session) {
        self.session = session
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard !inFlight else { return }
        let tabs = Array(session.claudeTabs().prefix(Self.perTick))
        guard !tabs.isEmpty else {
            session.noteClaudeModes([:])
            return
        }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var modes: [TabID: ClaudeMode?] = [:]
            for id in tabs {
                guard let screen = try? Daemon.preview(workspace: id.workspace, tab: id.root),
                      let declared = ClaudeMode.declared(onScreen: screen)
                else { continue }
                modes[id] = declared
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.session.noteClaudeModes(modes)
            }
        }
    }
}
